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

        default:
            break
        }
    }

    /// 依頼から司令塔が作る epic の id（司令塔の `EpicHandlers.epicID(for:)` と同じ決め方）
    static func epicID(forRequest envelope: IntentEnvelope) -> ULID {
        .derived(from: envelope.nonce, seed: "\(envelope.keyId)/epic")
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
            epics[epicIndex].history.insert(Epic.HistoryEntry(date: sentAt, text: "開始しました。司令塔が受け取るのを待っています"), at: 0)
        } else {
            epics[epicIndex].goal?.revisionRequest = envelope.string("instruction") ?? ""
            epics[epicIndex].activities.append(EpicActivity(kind: .revisingGoal, since: sentAt))
        }
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

    // MARK: 処理の結果

    /// 受け付けなかった意図を、対象の epic の履歴に失敗として出す
    func applyRejections(to epics: inout [Epic]) {
        for sent in documents.sentIntents {
            guard let consumed = sent.consumed, consumed.result == .rejected,
                  let epicID = sent.envelope.target?.epic?.rawValue ?? requestEpicID(sent.envelope),
                  let epicIndex = epics.firstIndex(where: { $0.id == epicID }) else {
                continue
            }
            let text = "\(Self.label(sent.envelope))を受け付けませんでした: \(consumed.reason ?? "理由は書かれていません")"
            epics[epicIndex].history.append(Epic.HistoryEntry(date: consumed.consumedAt.date, text: text, isFailure: true))
            epics[epicIndex].history.sort { $0.date > $1.date }
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
            title: [Self.label(envelope), epicTitle].compactMap(\.self).joined(separator: " · "),
            sentAt: envelope.issuedAt.date,
            state: state
        )
    }

    static func label(_ envelope: IntentEnvelope) -> String {
        let question = envelope.target?.id.map { "（\(displayID($0))）" } ?? ""
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
