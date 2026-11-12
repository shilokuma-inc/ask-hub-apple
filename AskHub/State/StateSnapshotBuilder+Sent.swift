import AskHubProtocol
import Foundation

// MARK: - 送った人の意図

extension StateSnapshotBuilder {
    /// 先に画面に出す意図（新しい順）。まだ読んでいないもの、司令塔がまだ処理していないもの、受け付けたのを読んだばかりのもの、
    /// 受け付けたが結果がまだ出ていないゴールの修正
    func intentsToOverlay() -> [IntentEnvelope] {
        unread + documents.sentIntents.filter { sent in
            switch sent.consumed?.result {
            case nil:
                return now.timeIntervalSince(sent.envelope.issuedAt.date) < Self.intentLifetime

            case .accepted:
                return sent.envelope.kind == ReviseGoalIntent.kind || justAccepted.contains(sent.envelope.nonce)

            case .rejected:
                return false
            }
        }
        .map(\.envelope)
    }

    /// この端末が送った意図（新しい順）。まだ読んでいないものは、処理を待つものとして先に並べる
    var sentIncludingUnread: [StateDocuments.SentIntent] {
        unread.map { StateDocuments.SentIntent(envelope: $0) } + documents.sentIntents
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

        case AbandonEpicIntent.kind, PauseEpicIntent.kind, ResumeEpicIntent.kind, HandoverIntent.kind:
            applyEpicControl(envelope, to: &epics, index: index)

        case ApproveMergeIntent.kind, InstructFinalIntent.kind:
            applyFinalIntent(envelope, to: &epics)

        default:
            // 判断のカードへの答えは、マージの規則と承認できるかの判定にも効くので、最終 PR を組み立てるときに当てる（`finalReview(of:index:)`）。
            // 人がする作業を終えた意図は、作業を組み立てるときに当てる（`humanTaskState(_:goal:epic:)`）
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
                    attachmentCount: Self.attachmentCount(envelope)
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
              let epicIndex = epics.firstIndex(where: { $0.id == epicID }), epics[epicIndex].isActive,
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
            let macID = envelope.string("mac")
            epics[epicIndex].stage = .implementing
            epics[epicIndex].macID = macID
            epics[epicIndex].workspace = .pending
            epics[epicIndex].activities.append(EpicActivity(kind: .startRequested(macID: macID), since: sentAt))
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
        let subject = subject(of: job)
        guard envelope.kind == GiveUpJobIntent.kind else {
            let text = "\(subject)のやり直しを頼みました。司令塔が受け取るのを待っています"
            epics[epicIndex].history.append(Epic.HistoryEntry(date: envelope.issuedAt.date, text: text))
            showRetryRequested(job, sentAt: envelope.issuedAt.date, in: &epics[epicIndex])
            return
        }
        // 司令塔（`GiveUpJobHandler`）と同じく、epic の段階を踏まえて扱いを決める
        let stage = documents.epics.first { $0.epic.id == job.epic }?.epic.stage
        switch stage.flatMap(job.kind.giveUpEffect(at:)) {
        case .abandonsEpic:
            epics[epicIndex].isAbandoned = true

        case .jobOnly:
            // 開始した後の epic に残っていた開始の前のジョブ（着手前の確認など）は、そのジョブだけを取り消す（epic はそのまま進む）
            if job.kind == .explain {
                reopenQuestion(of: job, in: &epics[epicIndex])
            } else if job.kind == .reviseGoal {
                epics[epicIndex].goal?.revisionRequest = nil
                epics[epicIndex].activities.removeAll { $0.kind == .revisingGoal }
            }

        case nil:
            return
        }
        let text = "\(subject)をやめました。司令塔が受け取るのを待っています"
        epics[epicIndex].history.append(Epic.HistoryEntry(date: envelope.issuedAt.date, text: text))
    }

    /// 段取りのジョブにやり直しを送ったら、受け取りまでの間も、止まったとは出さずに受け取り待ちを「いま」に出す
    private func showRetryRequested(_ job: JobFile, sentAt: Date, in epic: inout Epic) {
        let jobs = documents.epics.first { $0.epic.id == job.epic }?.jobs ?? []
        guard let step = step(of: job, jobs: jobs) else {
            return
        }
        switch step {
        case .prepareWorkspace:
            epic.workspace = .preparing

        case let .task(taskID, phase):
            if let index = epic.tasks.firstIndex(where: { $0.id == taskID }) {
                epic.tasks[index].state = .inProgress(phase)
            }

        case .final:
            break
        }
        let worker = job.assignedMac.map { EpicActivity.Worker(macID: $0.rawValue, heartbeatAt: nil) }
        epic.activities.append(EpicActivity(kind: .step(step, .retryRequested), since: sentAt, worker: worker))
    }

    /// マージの承認と最終 PR への指示。見た head が今の head と同じで、人が確かめる段階のときだけ出す（承認は、答え終えて押せるときだけ）
    private func applyFinalIntent(_ envelope: IntentEnvelope, to epics: inout [Epic]) {
        guard let epicID = envelope.target?.epic?.rawValue, let epicIndex = epics.firstIndex(where: { $0.id == epicID }),
              epics[epicIndex].isActive, let review = epics[epicIndex].finalReview, review.state == .reviewable,
              let head = review.headCommit, envelope.targetVersion == head else {
            return
        }
        let sentAt = envelope.issuedAt.date
        if envelope.kind == ApproveMergeIntent.kind {
            guard review.canMerge else {
                return
            }
            epics[epicIndex].finalReview?.state = .merging
            epics[epicIndex].activities.append(EpicActivity(kind: .mergeRequested, since: sentAt))
            epics[epicIndex].history.append(Epic.HistoryEntry(date: sentAt, text: "マージを承認しました。司令塔が受け取るのを待っています"))
        } else {
            // 受け取った司令塔は、最終 PR を直させてレビューからやり直す。それまで判断の確認とマージはできず、前のレビューの結果は今の結果として出さない
            epics[epicIndex].finalReview?.state = .checking
            epics[epicIndex].finalReview?.checks.ci = .fixingByRequest
            epics[epicIndex].finalReview?.checks.findings = nil
            epics[epicIndex].activities.append(EpicActivity(kind: .finalInstructionRequested, since: sentAt))
            let text = "最終 PR に指示しました。司令塔が受け取るのを待っています"
            epics[epicIndex].history.append(Epic.HistoryEntry(date: sentAt, text: text))
        }
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

    /// 版を持たずに epic を対象にする意図（取り下げ・一時停止・再開・引き継ぎ）
    private func applyEpicControl(_ envelope: IntentEnvelope, to epics: inout [Epic], index: StateIndex) {
        if envelope.kind == AbandonEpicIntent.kind {
            applyAbandon(envelope, to: &epics, index: index)
        } else {
            applyPauseIntent(envelope, to: &epics, index: index)
        }
    }

    /// 一時停止・再開・引き継ぎ。状態リポジトリにある、開始した後の epic だけに出す（司令塔が受け付けない状態なら出さない）
    private func applyPauseIntent(_ envelope: IntentEnvelope, to epics: inout [Epic], index: StateIndex) {
        guard let epicID = envelope.target?.epic?.rawValue, let entry = index.epics[epicID], entry.isStarted,
              let epicIndex = epics.firstIndex(where: { $0.id == epicID }), epics[epicIndex].isActive else {
            return
        }
        let sentAt = envelope.issuedAt.date
        var epic = epics[epicIndex]
        let text: String
        switch envelope.kind {
        case PauseEpicIntent.kind:
            guard !epic.isPaused else {
                return
            }
            epic.pausedAt = sentAt
            text = "一時停止しました。司令塔が受け取るのを待っています"

        case ResumeEpicIntent.kind:
            guard epic.isPaused else {
                return
            }
            epic.pausedAt = nil
            text = "再開しました。司令塔が受け取るのを待っています"

        default:
            // 一時停止していなければ、epic の Mac でジョブが動いている間は司令塔が断る
            guard let mac = envelope.string("mac"), mac != epic.macID, epic.isPaused || !entry.isBusyOnMac else {
                return
            }
            epic.macID = mac
            text = "\(mac) に引き継ぎました。司令塔が受け取るのを待っています"
        }
        epic.history.append(Epic.HistoryEntry(date: sentAt, text: text))
        epics[epicIndex] = epic
    }

    /// 一時停止・再開・引き継ぎを送れるか。処理を待つ意図を当てた後の epic で決める
    func applyPauseControls(of epic: Epic, to index: inout StateIndex) {
        guard let entry = index.epics[epic.id] else {
            return
        }
        let started = epic.isActive && entry.isStarted
        index.epics[epic.id]?.canPause = started && !epic.isPaused
        index.epics[epic.id]?.canResume = started && epic.isPaused
        index.epics[epic.id]?.canHandOver = started && (epic.isPaused || !entry.isBusyOnMac)
        index.epics[epic.id]?.mac = epic.macID.flatMap(MacName.init(rawValue:))
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
            state: state,
            target: Self.target(of: envelope)
        )
    }

    func label(_ envelope: IntentEnvelope) -> String {
        let question = envelope.target?.id.map { "（\(Self.displayID($0))）" } ?? ""
        // ジョブの名前は、読んだジョブから決める（終わった epic のジョブは読まないので、名前を付けないことがある）
        let job = job(targetedBy: envelope).map { "（\(subject(of: $0))）" } ?? ""
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
            return finalLabel(envelope) ?? pauseLabel(envelope) ?? envelope.kind
        }
    }

    /// 一時停止・再開・引き継ぎの呼び名。どれでもなければ nil
    private func pauseLabel(_ envelope: IntentEnvelope) -> String? {
        switch envelope.kind {
        case PauseEpicIntent.kind:
            "一時停止"

        case ResumeEpicIntent.kind:
            "再開"

        case HandoverIntent.kind:
            "引き継ぎ" + (envelope.string("mac").map { "（\($0)）" } ?? "")

        default:
            nil
        }
    }

    /// 最終 PR への意図の呼び名（例: 判断「見出しを短くした」への回答）。最終 PR への意図でなければ nil
    private func finalLabel(_ envelope: IntentEnvelope) -> String? {
        switch envelope.kind {
        case DecisionIntent.kind:
            let item = envelope.target.flatMap { target in
                documents.epics.first { $0.epic.id == target.epic }?.decisions?.items.first { $0.id == target.id }
            }
            return item.map { "判断「\($0.what)」への回答" } ?? "判断への回答"

        case ApproveMergeIntent.kind:
            return "マージの承認"

        case InstructFinalIntent.kind:
            return "最終 PR への指示"

        default:
            return nil
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
