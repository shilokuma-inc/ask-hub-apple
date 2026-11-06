import AskHubProtocol
import Foundation

// MARK: - epic・質問・ゴール

extension StateSnapshotBuilder {
    func epic(_ documents: StateDocuments.EpicDocuments, index: inout StateIndex) -> Epic {
        let file = documents.epic
        let id = file.id.rawValue
        let protocolQuestions = documents.questions?.questions ?? []
        index.epics[id] = StateIndex.EpicEntry(
            repo: file.repo,
            id: file.id,
            goalVersion: documents.goal?.version,
            readinessVersion: documents.readiness?.version
        )
        index.questions[id] = Dictionary(
            protocolQuestions.map { (Self.displayID($0.id), StateIndex.QuestionEntry(id: $0.id, version: $0.version)) },
            uniquingKeysWith: { first, _ in first }
        )
        // 見直しで要らなくなった質問は出さない（決まった扱い。依存する質問はすでに外れている）
        let questions = protocolQuestions.filter { $0.state != .dropped }.map { question($0, epic: file, readiness: documents.readiness) }
        let goal = documents.goal
        return Epic(
            id: id,
            title: file.title,
            repositoryID: Self.repository(file.repo).id,
            request: EpicRequest(
                summary: file.summary ?? file.title,
                body: requestBody(of: file),
                requestedAt: file.createdAt.date,
                source: .app,
                attachmentCount: 0
            ),
            stage: file.stage == .abandoned ? Self.abandonedStage(documents) : Self.stage(file.stage),
            questions: questions,
            goal: goal.map(Self.goal),
            humanTasks: goal.map(Self.humanTasks) ?? [],
            tasks: goal.map(Self.tasks) ?? [],
            macID: file.mac?.rawValue,
            activities: activities(of: file, questions: questions),
            blocker: nil,
            finalReview: nil,
            history: history(of: file, questions: protocolQuestions, readiness: documents.readiness),
            updatedAt: file.updatedAt.date,
            split: Self.split(file.stage, readiness: documents.readiness),
            isAbandoned: file.stage == .abandoned
        )
    }

    /// やめた epic の段階。epic のファイルは「やめた」だけを持つので、どこまで進んでいたかをほかのファイルから決める
    private static func abandonedStage(_ documents: StateDocuments.EpicDocuments) -> Epic.Stage {
        let file = documents.epic
        if file.finalPullRequest != nil {
            return .finalReview
        }
        if file.branch != nil || file.mac != nil {
            return .implementing
        }
        if documents.goal != nil || documents.readiness != nil {
            return .preflight
        }
        return documents.questions?.questions.isEmpty == false ? .questions : .request
    }

    /// 依頼の本文は epic のファイルに無いので、この端末が送った依頼なら、送った意図から読む
    private func requestBody(of file: EpicFile) -> String {
        guard let origin = file.origin,
              let sent = documents.sentIntents.first(where: { $0.envelope.keyId == origin.keyId && $0.envelope.nonce == origin.nonce }),
              case .string(let body)? = sent.envelope.payload?["body"] else {
            return ""
        }
        return body
    }

    static func displayID(_ id: String) -> Question.ID {
        id.uppercased()
    }

    static func stage(_ stage: EpicStage) -> Epic.Stage {
        switch stage {
        case .drafting: .request
        case .asking: .questions
        case .checking, .awaitingSplit: .preflight
        case .awaitingStart: .goal
        case .running: .implementing
        case .finalizing, .reviewing: .finalReview
        case .merged, .abandoned: .done
        }
    }

    private static func split(_ stage: EpicStage, readiness: ReadinessFile?) -> SplitProposal? {
        guard let readiness, readiness.verdict == .tooLarge else {
            return nil
        }
        let choice: SplitChoice? = switch stage {
        case .awaitingSplit: nil
        case .abandoned: .split
        default: readiness.proceeding == true ? .proceed : nil
        }
        // 「このまま進める」と決めた後は、分け方の案を出し続けない
        guard stage == .awaitingSplit || choice == .split else {
            return nil
        }
        return SplitProposal(
            reason: readiness.reason,
            parts: readiness.split.map { SplitProposal.Part(title: $0.title, summary: $0.summary) },
            choice: choice
        )
    }

    private func activities(of file: EpicFile, questions: [Question]) -> [EpicActivity] {
        var activities: [EpicActivity] = []
        switch file.stage {
        case .drafting:
            activities.append(EpicActivity(kind: .writingQuestions, since: file.updatedAt.date))

        case .checking:
            activities.append(EpicActivity(kind: .checkingAnswers, since: file.updatedAt.date))

        default:
            break
        }
        for question in questions {
            switch question.state {
            case .awaitingExplanation(let requestedAt):
                activities.append(EpicActivity(kind: .explaining(question.id), since: requestedAt))

            case .reviewing:
                activities.append(EpicActivity(kind: .reviewing(question.id), since: file.updatedAt.date))

            case .open, .locked, .answered:
                break
            }
        }
        return activities
    }

    private func history(of file: EpicFile, questions: [QuestionsFile.Question], readiness: ReadinessFile?) -> [Epic.HistoryEntry] {
        var entries = [Epic.HistoryEntry(date: file.createdAt.date, text: "依頼しました")]
        for question in questions {
            if let answer = question.answer {
                entries.append(Epic.HistoryEntry(date: answer.at.date, text: "\(Self.displayID(question.id)) に回答しました"))
            }
            if question.state == .dropped, let revision = question.revision {
                let text = "\(Self.displayID(question.id)) は要らなくなりました（\(revision.reason)）"
                entries.append(Epic.HistoryEntry(date: file.updatedAt.date, text: text))
            }
        }
        if let readiness {
            entries.append(Epic.HistoryEntry(date: readiness.checkedAt.date, text: "着手前の確認（\(readiness.round) 回目）: \(readiness.reason)"))
        }
        return entries.sorted { $0.date > $1.date }
    }

    // MARK: 質問

    private func question(_ question: QuestionsFile.Question, epic: EpicFile, readiness: ReadinessFile?) -> Question {
        // プロトコルの質問には、いつも選択肢があり、推奨はそのどれか（自由記述は、人が選択肢の外の答えとして書く）
        Question(
            id: Self.displayID(question.id),
            title: question.title,
            why: question.why,
            // 回答では、選んだ選択肢を label で送る
            options: question.options.map { Question.Option(id: $0.label, label: $0.label, effect: $0.effect) },
            recommendedOptionID: question.recommended,
            recommendationReason: question.reason,
            dependsOn: question.dependsOn.map(Self.displayID),
            state: state(of: question),
            explanations: question.explanations.map { explanation in
                // 説明の記録の時刻は 1 つだけなので、書き終えた説明は、その時刻に書いたことにする
                let date = explanation.at.date
                return Question.Explanation(
                    request: explanation.note,
                    requestedAt: date,
                    body: explanation.text,
                    answeredAt: explanation.text.map { _ in date }
                )
            },
            revisionNote: question.revision?.reason,
            // 質問に時刻は無いので、最初の質問づくりなら依頼の時刻、追加の質問なら着手前の確認の時刻にする
            askedAt: question.round == 1 ? epic.createdAt.date : readiness?.checkedAt.date ?? epic.updatedAt.date,
            caution: question.caution.map { Self.caution($0.kind) }
        )
    }

    private func state(of question: QuestionsFile.Question) -> Question.State {
        switch question.state {
        case .locked:
            return .locked

        case .revising:
            return .reviewing

        case .open:
            return .open

        case .clarifying:
            return .awaitingExplanation(requestedAt: question.explanations.last?.at.date ?? now)

        case .answered, .dropped:
            guard let answer = question.answer else {
                return .open
            }
            return .answered(Question.Response(optionID: answer.choice, note: answer.note, answeredAt: answer.at.date))
        }
    }

    private static func caution(_ kind: AskHubProtocol.Caution.Kind) -> Caution {
        switch kind {
        case .security: .security
        case .privacy: .privacy
        case .irreversible: .irreversible
        case .cost: .cost
        }
    }

    // MARK: ゴール

    private static func goal(_ file: GoalFile) -> Goal {
        let humanTaskIDs = Set(file.humanTasks.map(\.id))
        return Goal(
            version: file.version,
            summary: file.summary,
            decided: file.decided.map { Goal.Point(text: $0.text, questionID: displayID($0.question)) },
            notDoing: file.outOfScope,
            doneCriteria: file.doneWhen,
            tasks: file.tasks.map { Goal.PlannedTask(title: $0.title, humanTaskID: $0.dependsOn.first { humanTaskIDs.contains($0) }) },
            revisionRequest: nil,
            notApplied: file.notApplied ?? []
        )
    }

    private static func tasks(_ file: GoalFile) -> [EpicTask] {
        file.tasks.enumerated().map { offset, task in
            let state: EpicTask.State = switch task.state {
            case .pending: .pending
            case .locked: .locked(reason: "人がする作業を待っています")
            case .running: .inProgress
            case .done: .done(pullRequest: nil)
            }
            return EpicTask(id: task.id, number: offset + 1, title: task.title, state: state)
        }
    }

    private static func humanTasks(_ file: GoalFile) -> [HumanTask] {
        file.humanTasks.map { task in
            HumanTask(
                id: task.id,
                title: task.title,
                why: task.why,
                steps: task.steps.map { HumanTask.Step(text: $0) },
                links: task.links.compactMap { link in URL(string: link).map { HumanTask.Link(title: $0.host() ?? link, url: $0) } },
                deliverable: deliverable(task.handover),
                blocksTaskIDs: file.tasks.filter { $0.dependsOn.contains(task.id) }.map(\.id),
                state: task.state == .done ? .done : .todo
            )
        }
    }

    private static func deliverable(_ handover: GoalFile.Handover) -> HumanTask.Deliverable {
        switch handover.kind {
        case .none: .none
        case .file: .file(description: "ファイルを渡す")
        case .secret: .secret(name: handover.name ?? "", repository: "")
        }
    }
}
