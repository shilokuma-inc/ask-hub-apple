import AskHubProtocol
import Foundation

// MARK: - 送った人の意図

extension StateSnapshotBuilder {
    /// 先に画面に出す意図。司令塔がまだ処理していないものと、受け付けたが結果がまだ出ていないゴールの修正
    func intentsToOverlay() -> [IntentEnvelope] {
        documents.sentIntents.filter { sent in
            switch sent.consumed?.result {
            case nil:
                return now.timeIntervalSince(sent.envelope.issuedAt.date) < Self.intentLifetime

            case .accepted:
                return sent.envelope.kind == ReviseGoalIntent.kind

            case .rejected:
                return false
            }
        }
        .map(\.envelope)
    }

    /// 送った意図を、送った結果として画面に出す。送った後に対象が変わっていれば（司令塔が断る）、出さない
    func apply(_ envelope: IntentEnvelope, to epics: inout [Epic], repositories: inout [TargetRepository], index: inout StateIndex) {
        switch envelope.kind {
        case RequestIntent.kind:
            applyRequest(envelope, to: &epics)

        case AddRepositoryIntent.kind:
            guard let repo = envelope.repo, index.repositories[Self.repository(repo).id] == nil else {
                return
            }
            repositories.append(Self.repository(repo))
            index.repositories[Self.repository(repo).id] = repo

        case AnswerIntent.kind:
            applyAnswer(envelope, to: &epics, index: index)

        case ReviseGoalIntent.kind, StartEpicIntent.kind:
            applyGoalIntent(envelope, to: &epics)

        case DecideSplitIntent.kind:
            applyDecideSplit(envelope, to: &epics, index: index)

        case RetryJobIntent.kind, GiveUpJobIntent.kind:
            applyJobIntent(envelope, to: &epics)

        case AbandonEpicIntent.kind:
            applyAbandon(envelope, to: &epics, index: index)

        default:
            break
        }
    }

    /// 依頼から司令塔が作る epic の id（司令塔と同じ `RequestIntent.epicID(for:)` で決める）
    static func epicID(forRequest envelope: IntentEnvelope) -> ULID {
        RequestIntent.epicID(for: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    private func applyRequest(_ envelope: IntentEnvelope, to epics: inout [Epic]) {
        let id = Self.epicID(forRequest: envelope).rawValue
        guard let repo = envelope.repo, !epics.contains(where: { $0.id == id }) else {
            return
        }
        let title = envelope.string("title") ?? "依頼"
        let sentAt = envelope.issuedAt.date
        epics.append(
            Epic(
                id: id,
                title: title,
                repositoryID: Self.repository(repo).id,
                request: EpicRequest(
                    summary: title,
                    body: envelope.string("body") ?? "",
                    requestedAt: sentAt,
                    source: .app,
                    attachmentCount: 0
                ),
                stage: .request,
                questions: [],
                goal: nil,
                humanTasks: [],
                tasks: [],
                macID: nil,
                activities: [],
                blocker: nil,
                finalReview: nil,
                history: [Epic.HistoryEntry(date: sentAt, text: "依頼を送りました。司令塔が受け取るのを待っています")],
                updatedAt: sentAt
            )
        )
    }

    private func applyAnswer(_ envelope: IntentEnvelope, to epics: inout [Epic], index: StateIndex) {
        guard let epicID = envelope.target?.epic?.rawValue, let protocolID = envelope.target?.id,
              let epicIndex = epics.firstIndex(where: { $0.id == epicID }),
              let questionIndex = epics[epicIndex].questions.firstIndex(where: { $0.id == Self.displayID(protocolID) }),
              let entry = index.questions[epicID]?[Self.displayID(protocolID)], envelope.targetVersion == String(entry.version) else {
            return
        }
        let sentAt = envelope.issuedAt.date
        let note = envelope.string("note") ?? ""
        var question = epics[epicIndex].questions[questionIndex]
        if envelope.string("mode") == "clarify" {
            guard question.state == .open else {
                return
            }
            question.state = .awaitingExplanation(requestedAt: sentAt)
            question.explanations.append(Question.Explanation(request: note, requestedAt: sentAt))
            epics[epicIndex].activities.append(EpicActivity(kind: .explaining(question.id), since: sentAt))
        } else {
            switch question.state {
            case .open, .answered:
                question.state = .answered(Question.Response(optionID: envelope.string("choice"), note: note, answeredAt: sentAt))

            case .awaitingExplanation, .locked, .reviewing:
                return
            }
        }
        epics[epicIndex].questions[questionIndex] = question
    }

    /// 開始とゴールの修正。どちらも、確かめたゴールの版が今のゴールと同じで、開始の待ちのときだけ出す
    private func applyGoalIntent(_ envelope: IntentEnvelope, to epics: inout [Epic]) {
        guard let epicID = envelope.target?.epic?.rawValue, let epicIndex = epics.firstIndex(where: { $0.id == epicID }),
              epics[epicIndex].stage == .goal, let goal = epics[epicIndex].goal, envelope.targetVersion == String(goal.version) else {
            return
        }
        let sentAt = envelope.issuedAt.date
        if envelope.kind == StartEpicIntent.kind {
            epics[epicIndex].stage = .implementing
            epics[epicIndex].macID = envelope.string("mac")
            epics[epicIndex].history.append(Epic.HistoryEntry(date: sentAt, text: "開始しました。司令塔が受け取るのを待っています"))
            return
        }
        // 受け付けた修正のジョブを人がやめた（取り消された・やめるを送った）なら、前のゴールのまま開始を待つ
        let origin = IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        let job = documents.epics.first { $0.epic.id.rawValue == epicID }?.jobs.first { $0.origin == origin }
        if let job, [.canceled, .failed].contains(job.state) || isGivenUp(job) {
            return
        }
        epics[epicIndex].goal?.revisionRequest = envelope.string("instruction") ?? ""
        // 人に渡されて止まっている間は、`applyBlockers` が外す（やり直しを送ったら、また直している途中として出る）
        epics[epicIndex].activities.append(EpicActivity(kind: .revisingGoal, since: sentAt))
    }

    private func applyDecideSplit(_ envelope: IntentEnvelope, to epics: inout [Epic], index: StateIndex) {
        guard let epicID = envelope.target?.epic?.rawValue, let epicIndex = epics.firstIndex(where: { $0.id == epicID }),
              var split = epics[epicIndex].split, split.choice == nil,
              let version = index.epics[epicID]?.readinessVersion, envelope.targetVersion == String(version) else {
            return
        }
        let choice: SplitChoice = envelope.string("choice") == DecideSplitIntent.Choice.split.rawValue ? .split : .proceed
        split.choice = choice
        switch choice {
        case .split:
            epics[epicIndex].split = split
            epics[epicIndex].isAbandoned = true

        case .proceed:
            epics[epicIndex].split = nil
            epics[epicIndex].activities.append(EpicActivity(kind: .checkingAnswers, since: envelope.issuedAt.date))
        }
    }

    /// やり直す・やめる。対象のジョブが人の見たときのまま、人の対応を待っているときだけ出す（「対処が要ります」は `applyBlockers` が外す）
    private func applyJobIntent(_ envelope: IntentEnvelope, to epics: inout [Epic]) {
        guard let job = waitingJob(targetedBy: envelope), let epicIndex = epics.firstIndex(where: { $0.id == job.epic.rawValue }) else {
            return
        }
        let subject = Self.subject(of: job)
        guard envelope.kind == GiveUpJobIntent.kind else {
            let text = "\(subject)のやり直しを頼みました。司令塔が受け取るのを待っています"
            epics[epicIndex].history.append(Epic.HistoryEntry(date: envelope.issuedAt.date, text: text))
            return
        }
        if Self.epicEndingKinds.contains(job.kind) {
            epics[epicIndex].isAbandoned = true
        } else if job.kind == .explain {
            reopenQuestion(of: job, in: &epics[epicIndex])
        } else if job.kind == .reviseGoal {
            epics[epicIndex].goal?.revisionRequest = nil
            epics[epicIndex].activities.removeAll { $0.kind == .revisingGoal }
        } else {
            return
        }
        let text = "\(subject)をやめました。司令塔が受け取るのを待っています"
        epics[epicIndex].history.append(Epic.HistoryEntry(date: envelope.issuedAt.date, text: text))
    }

    /// 取り下げ。状態リポジトリにある、開始する前の epic だけを出す（開始した後は司令塔が断る）
    private func applyAbandon(_ envelope: IntentEnvelope, to epics: inout [Epic], index: StateIndex) {
        guard let epicID = envelope.target?.epic?.rawValue, index.epics[epicID] != nil,
              let epicIndex = epics.firstIndex(where: { $0.id == epicID }),
              epics[epicIndex].isActive, epics[epicIndex].stage < .implementing else {
            return
        }
        epics[epicIndex].isAbandoned = true
        let text = "取り下げました。司令塔が受け取るのを待っています"
        epics[epicIndex].history.append(Epic.HistoryEntry(date: envelope.issuedAt.date, text: text))
    }

    /// 処理を待つやめるの意図を送ったジョブか（同じ秒に送った意図の順に頼らずに決める）
    private func isGivenUp(_ job: JobFile) -> Bool {
        intentsToOverlay().contains { $0.kind == GiveUpJobIntent.kind && waitingJob(targetedBy: $0)?.id == job.id }
    }

    /// 説明をやめたら、説明を待つ問いを外して質問を回答待ちに戻す（司令塔の `QuestionFlow.abandonExplanation` と同じ）
    private func reopenQuestion(of job: JobFile, in epic: inout Epic) {
        guard let questionID = Self.questionID(of: job), let questionIndex = epic.questions.firstIndex(where: { $0.id == questionID }),
              case .awaitingExplanation = epic.questions[questionIndex].state else {
            return
        }
        epic.questions[questionIndex].state = .open
        epic.questions[questionIndex].explanations.removeAll { $0.body == nil }
        epic.activities.removeAll { $0.kind == .explaining(questionID) }
    }

    // MARK: 処理の結果

    /// 受け付けなかった意図を、対象の epic の履歴に失敗として出す
    func applyRejections(to epics: inout [Epic]) {
        for sent in documents.sentIntents {
            guard let consumed = sent.consumed, consumed.result == .rejected,
                  let epicID = sent.envelope.target?.epic?.rawValue ?? requestEpicID(sent.envelope),
                  let epicIndex = epics.firstIndex(where: { $0.id == epicID }) else {
                continue
            }
            let text = "\(label(sent.envelope))を受け付けませんでした: \(consumed.reason ?? "理由は書かれていません")"
            epics[epicIndex].history.append(Epic.HistoryEntry(date: consumed.consumedAt.date, text: text, isFailure: true))
            epics[epicIndex].history.sort { $0.date < $1.date }
        }
    }

    private func requestEpicID(_ envelope: IntentEnvelope) -> Epic.ID? {
        envelope.kind == RequestIntent.kind ? Self.epicID(forRequest: envelope).rawValue : nil
    }

    func sentStatus(_ sent: StateDocuments.SentIntent) -> SentIntentStatus {
        let envelope = sent.envelope
        let epicTitle = envelope.target?.epic.flatMap { id in documents.epics.first { $0.epic.id == id }?.epic.title }
        let state: SentIntentStatus.State
        switch sent.consumed {
        case nil where now.timeIntervalSince(envelope.issuedAt.date) < Self.intentLifetime:
            state = .waiting

        case nil:
            state = .rejected(at: envelope.issuedAt.date, reason: "有効期間（7 日）を過ぎました")

        case let consumed? where consumed.result == .accepted:
            state = .accepted(at: consumed.consumedAt.date)

        case let consumed?:
            state = .rejected(at: consumed.consumedAt.date, reason: consumed.reason ?? "理由は書かれていません")
        }
        return SentIntentStatus(
            id: envelope.nonce.rawValue,
            title: [label(envelope), epicTitle].compactMap(\.self).joined(separator: " · "),
            sentAt: envelope.issuedAt.date,
            state: state
        )
    }

    func label(_ envelope: IntentEnvelope) -> String {
        let question = envelope.target?.id.map { "（\(Self.displayID($0))）" } ?? ""
        // ジョブの名前は、読んだジョブから決める（終わった epic のジョブは読まないので、名前を付けないことがある）
        let job = job(targetedBy: envelope).map { "（\(Self.subject(of: $0))）" } ?? ""
        switch envelope.kind {
        case RequestIntent.kind:
            return "依頼「\(envelope.string("title") ?? "")」"

        case AnswerIntent.kind:
            return (envelope.string("mode") == "clarify" ? "説明の依頼" : "回答") + question

        case StartEpicIntent.kind:
            return "開始"

        case ReviseGoalIntent.kind:
            return "ゴールの修正"

        case DecideSplitIntent.kind:
            return "分け方の判断"

        case AddRepositoryIntent.kind:
            return "対象に加える（\(envelope.repo?.rawValue ?? "")）"

        case RetryJobIntent.kind:
            return "やり直し" + job

        case GiveUpJobIntent.kind:
            return "取りやめ" + job

        case AbandonEpicIntent.kind:
            return "取り下げ"

        default:
            return envelope.kind
        }
    }
}

extension IntentEnvelope {
    /// payload の文字列の値
    func string(_ key: String) -> String? {
        guard case .string(let value)? = payload?[key] else {
            return nil
        }
        return value
    }
}
