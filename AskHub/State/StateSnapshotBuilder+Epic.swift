import AskHubProtocol
import Foundation

// MARK: - epic・質問・ゴール

extension StateSnapshotBuilder {
    func epic(_ documents: StateDocuments.EpicDocuments, index: inout StateIndex) -> Epic {
        let file = documents.epic
        let id = file.id.rawValue
        let protocolQuestions = documents.questions?.questions ?? []
        let shownHumanTasks = documents.goal.map { humanTasks($0, epic: file) } ?? []
        index.epics[id] = StateIndex.EpicEntry(
            repo: file.repo,
            id: file.id,
            goalVersion: documents.goal?.version,
            readinessVersion: documents.readiness?.version,
            humanTasks: Self.completableHumanTasks(file.stage, goal: documents.goal, shown: shownHumanTasks)
        )
        index.questions[id] = Dictionary(
            protocolQuestions.map { (Self.displayID($0.id), StateIndex.QuestionEntry(id: $0.id, version: $0.version)) },
            uniquingKeysWith: { first, _ in first }
        )
        // 見直しで要らなくなった質問は出さない（決まった扱い。依存する質問はすでに外れている）
        let questions = protocolQuestions.filter { $0.state != .dropped }.map { question($0, epic: file, readiness: documents.readiness) }
        let goal = documents.goal
        let progress = progress(of: documents)
        let finalReview = finalReview(of: documents, index: &index)
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
            humanTasks: shownHumanTasks,
            tasks: progress.tasks,
            macID: file.mac?.rawValue,
            activities: activities(of: file, questions: questions) + progress.activities,
            blocker: nil,
            finalReview: finalReview,
            history: (history(of: file, questions: protocolQuestions, readiness: documents.readiness) + progress.history
                + finalHistory(of: documents, review: finalReview))
                .sorted { $0.date < $1.date },
            updatedAt: file.updatedAt.date,
            split: Self.split(file.stage, readiness: documents.readiness),
            isAbandoned: file.stage == .abandoned,
            workspace: progress.workspace
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

    /// 開始する前の履歴。画面（`HistorySection`）は古い順の履歴を新しい順に並べ替えて出すので、段取りの履歴と合わせて古い順にする
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
        return entries
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

    // MARK: 人がする作業

    /// 終えたことを送れる人がする作業（司令塔が `humanTaskDone` を受け付ける段階の、終えていなくて、送った「終えた」の処理を待っていないもの）
    private static func completableHumanTasks(_ stage: EpicStage, goal: GoalFile?, shown: [HumanTask]) -> [HumanTask.ID: HandoverKind] {
        guard [.awaitingStart, .running].contains(stage), let goal else {
            return [:]
        }
        let waiting = Set(shown.filter { !$0.needsHuman }.map(\.id))
        return Dictionary(
            goal.humanTasks.filter { $0.state == .pending && !waiting.contains($0.id) }.map { ($0.id, $0.handover.kind) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func humanTasks(_ file: GoalFile, epic: EpicFile) -> [HumanTask] {
        file.humanTasks.map { task in
            HumanTask(
                id: task.id,
                title: task.title,
                why: task.why,
                steps: task.steps.map { HumanTask.Step(text: $0) },
                links: task.links.compactMap { link in URL(string: link).map { HumanTask.Link(title: $0.host() ?? link, url: $0) } },
                deliverable: Self.deliverable(task.handover, repo: epic.repo),
                blocksTaskIDs: file.tasks.filter { $0.dependsOn.contains(task.id) }.map(\.id),
                state: humanTaskState(task, goal: file, epic: epic)
            )
        }
    }

    /// 終えていない作業は、この端末が最後に送った「終えた」で出し分ける: 処理を待っていれば司令塔が確かめている間（もう一度は送らせない）、
    /// 断られていれば断った理由（直して送り直してもらう）
    private func humanTaskState(_ task: GoalFile.HumanTask, goal: GoalFile, epic: EpicFile) -> HumanTask.State {
        guard task.state == .pending else {
            return .done
        }
        // 送った意図は新しい順
        let latest = documents.sentIntents.first { sent in
            sent.envelope.kind == HumanTaskDoneIntent.kind && sent.envelope.target?.epic == epic.id && sent.envelope.target?.id == task.id
        }
        guard let latest else {
            return .todo
        }
        switch latest.consumed?.result {
        case nil:
            // 古いゴールの版で送ったもの・期限を過ぎたものは、司令塔が断る
            let isLive = now.timeIntervalSince(latest.envelope.issuedAt.date) < Self.intentLifetime
            return isLive && latest.envelope.targetVersion == String(goal.version) ? .verifying : .todo

        case .rejected?:
            return .verificationFailed(reason: latest.consumed?.reason ?? "理由は書かれていません")

        case .accepted?:
            return .todo
        }
    }

    private static func deliverable(_ handover: GoalFile.Handover, repo: RepositoryFullName) -> HumanTask.Deliverable {
        switch handover.kind {
        case .none: .none
        case .file: .file(description: "ファイルを渡す")
        case .secret: .secret(name: handover.name ?? "", repository: repo.rawValue)
        }
    }
}
