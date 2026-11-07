import Foundation

// MARK: - 人の意図を当てる（依頼から開始まで）

extension DemoClientService {
    func apply(_ intent: HumanIntent) -> SendReceipt {
        switch intent {
        case let .request(repositoryID, summary, body):
            return SendReceipt(requestedEpicID: addRequest(repositoryID: repositoryID, summary: summary, body: body))

        case .answer, .requestExplanation:
            applyQuestionIntent(intent)

        case .reviseGoal, .start, .decideSplit, .addRepository:
            applySetupIntent(intent)

        case .respondToDecision, .acceptAllDecisions, .merge, .verify:
            applyReviewIntent(intent)

        case .resolveBlocker, .handOver, .pause, .resume, .discard, .completeHumanTask, .submitSecret, .cleanUp:
            applyOperationIntent(intent)
        }
        return SendReceipt()
    }

    private func applyQuestionIntent(_ intent: HumanIntent) {
        switch intent {
        case let .answer(epicID, questionID, optionID, note):
            answer(epicID: epicID, questionID: questionID, optionID: optionID, note: note)

        case let .requestExplanation(epicID, questionID, request):
            requestExplanation(epicID: epicID, questionID: questionID, request: request)

        default:
            break
        }
    }

    private func applySetupIntent(_ intent: HumanIntent) {
        switch intent {
        case let .reviseGoal(epicID, request):
            reviseGoal(epicID: epicID, request: request)

        case let .start(epicID, macID):
            start(epicID: epicID, macID: macID)

        case let .decideSplit(epicID, choice):
            decideSplit(epicID: epicID, choice: choice)

        case .addRepository(let repositoryID):
            guard let repository = state.candidateRepositories.first(where: { $0.id == repositoryID }) else {
                return
            }
            state.candidateRepositories.removeAll { $0.id == repositoryID }
            state.repositories.append(repository)

        default:
            break
        }
    }

    private func answer(epicID: Epic.ID, questionID: Question.ID, optionID: Question.Option.ID?, note: String) {
        let date = now()
        state.updateEpic(epicID) { epic in
            // 開始の前に回答を変えたら、依存する質問の回答を取り消してロックに戻し、見直しからやり直す
            if let question = epic.question(questionID), question.isSettled {
                for dependent in epic.questions.dependents(of: question) {
                    epic.updateQuestion(dependent.id) {
                        $0.state = .locked
                        $0.revisionNote = nil
                    }
                }
            }
            epic.updateQuestion(questionID) {
                $0.state = .answered(Question.Response(optionID: optionID, note: note, answeredAt: date))
            }
            epic.log("\(questionID) に回答しました", at: date)
        }
        questionSettled(epicID: epicID, questionID: questionID)
    }

    private func requestExplanation(epicID: Epic.ID, questionID: Question.ID, request: String) {
        let date = now()
        state.updateEpic(epicID) { epic in
            epic.updateQuestion(questionID) {
                $0.state = .awaitingExplanation(requestedAt: date)
                $0.explanations.append(Question.Explanation(request: request, requestedAt: date))
            }
            epic.activities.append(EpicActivity(kind: .explaining(questionID), since: date))
            epic.log("\(questionID) の説明を求めました", at: date)
        }
        schedule(after: 1.5) { [now] snapshot in
            let answeredAt = now()
            snapshot.updateEpic(epicID) { epic in
                epic.updateQuestion(questionID) { question in
                    let index = question.explanations.count - 1
                    if index >= 0 {
                        question.explanations[index].body = Self.explanationText(for: question)
                        question.explanations[index].answeredAt = answeredAt
                    }
                    question.state = .open
                }
                epic.removeActivities { $0 == .explaining(questionID) }
                epic.log("\(questionID) の説明が届きました", at: answeredAt)
            }
        }
    }

    static func explanationText(for question: Question) -> String {
        let recommended = question.recommendedOption?.label ?? "推奨の選択肢"
        return """
        リポジトリを読んで確かめました。「\(question.title)」は、\(question.why)。
        今の作りでは、画面の一覧は 1 つだけで、ここで言う「一覧」はその画面を指します。
        どれを選んでも後から変えられますが、迷ったら「\(recommended)」で始めるのがいちばん小さく済みます。
        """
    }

    /// 質問が決まったら、依存する質問の見直しと、すべて決まったときの着手前の確認を進める
    private func questionSettled(epicID: Epic.ID, questionID: Question.ID) {
        let date = now()
        guard let epic = state.epic(epicID) else {
            return
        }
        let unlocked = epic.questions.filter { question in
            question.state == .locked && question.dependsOn.allSatisfy { epic.question($0)?.isSettled ?? true }
        }
        for question in unlocked {
            state.updateEpic(epicID) { epic in
                epic.updateQuestion(question.id) { $0.state = .reviewing }
                epic.activities.append(EpicActivity(kind: .reviewing(question.id), since: date))
            }
            schedule { [now] snapshot in
                snapshot.updateEpic(epicID) { epic in
                    let note = question.dependsOn.joined(separator: "・")
                    epic.updateQuestion(question.id) {
                        $0.state = .open
                        $0.revisionNote = "\(note) の回答に合わせて、質問と選択肢を見直しました"
                    }
                    epic.removeActivities { $0 == .reviewing(question.id) }
                    epic.log("\(question.id) のロックが外れました", at: now())
                }
            }
        }
        startPreflightIfReady(epicID: epicID)
    }

    private func startPreflightIfReady(epicID: Epic.ID) {
        guard let epic = state.epic(epicID), epic.stage == .questions, epic.questions.allSatisfy(\.isSettled) else {
            return
        }
        let date = now()
        state.updateEpic(epicID) { epic in
            epic.stage = .preflight
            epic.activities = [EpicActivity(kind: .checkingAnswers, since: date)]
            epic.log("すべての質問が決まりました。着手前の確認をしています", at: date)
        }
        schedule(after: 1.5) { [now] snapshot in
            snapshot.updateEpic(epicID) { epic in
                epic.stage = .goal
                epic.activities = []
                epic.goal = epic.goal ?? Self.makeGoal(for: epic)
                epic.log("着手前の確認が終わり、ゴールを作りました", at: now())
            }
        }
    }

    static func makeGoal(for epic: Epic) -> Goal {
        let decided = epic.questions.compactMap { question -> Goal.Point? in
            guard case .answered(let response) = question.state else {
                return nil
            }
            let text = question.answeredOption?.label ?? response.note
            return Goal.Point(text: "\(question.title): \(text)", questionID: question.id)
        }
        return Goal(
            version: 1,
            summary: epic.request.summary,
            decided: decided,
            notDoing: ["依頼の範囲の外の画面の作り直し"],
            doneCriteria: ["依頼の内容がデモのデータで確かめられる", "Unit テストが通る"],
            tasks: [
                Goal.PlannedTask(title: "モデルと保存", humanTaskID: nil),
                Goal.PlannedTask(title: "画面", humanTaskID: nil),
                Goal.PlannedTask(title: "デモのデータとテスト", humanTaskID: nil)
            ],
            revisionRequest: nil
        )
    }

    private func reviseGoal(epicID: Epic.ID, request: String) {
        let date = now()
        state.updateEpic(epicID) { epic in
            epic.goal?.revisionRequest = request
            epic.activities = [EpicActivity(kind: .revisingGoal, since: date)]
            epic.log("ゴールの直しを頼みました", at: date)
        }
        schedule(after: 1.5) { [now] snapshot in
            snapshot.updateEpic(epicID) { epic in
                guard var goal = epic.goal else {
                    return
                }
                goal.version += 1
                goal.decided.append(Goal.Point(text: "直したこと: \(request)", questionID: nil))
                goal.revisionRequest = nil
                epic.goal = goal
                epic.activities = []
                epic.log("ゴールを直しました（版 \(goal.version)）", at: now())
            }
        }
    }

    private func decideSplit(epicID: Epic.ID, choice: SplitChoice) {
        let date = now()
        state.updateEpic(epicID) { epic in
            switch choice {
            case .split:
                epic.split?.choice = .split
                epic.isAbandoned = true
                epic.activities = []
                epic.log("分けて依頼し直すことにしました", at: date)

            case .proceed:
                epic.split = nil
                epic.activities = [EpicActivity(kind: .checkingAnswers, since: date)]
                epic.log("このまま 1 つで進めることにしました", at: date)
            }
        }
    }

    private func start(epicID: Epic.ID, macID: Mac.ID) {
        let date = now()
        state.updateEpic(epicID) { epic in
            if epic.tasks.isEmpty, let goal = epic.goal {
                epic.tasks = goal.tasks.enumerated().map { index, task in
                    EpicTask(id: "\(epic.id)-t\(index + 1)", number: index + 1, title: task.title, state: .pending)
                }
            }
            if let first = epic.tasks.firstIndex(where: { $0.state == .pending }) {
                epic.tasks[first].state = .inProgress
                epic.activities = [EpicActivity(kind: .implementing(taskID: epic.tasks[first].id, attempt: 1), since: date)]
            }
            epic.stage = .implementing
            epic.macID = macID
            epic.log("開始しました", at: date)
        }
        let macName = state.mac(macID)?.name ?? macID
        let title = state.epic(epicID)?.title ?? ""
        state.updateMac(macID) { mac in
            mac.jobs.append(Mac.Job(id: "job-\(epicID)", title: "\(title): タスク 1 の実装", epicID: epicID, startedAt: date))
        }
        state.updateEpic(epicID) { $0.log("\(macName) で実装を始めました", at: date) }
        state.recordLastMac(macID, forEpic: epicID)
    }

    /// 依頼を epic にして、その id を返す
    private func addRequest(repositoryID: TargetRepository.ID, summary: String, body: String) -> Epic.ID {
        let date = now()
        let id = "request-\(Int(date.timeIntervalSince1970))"
        let epic = Epic(
            id: id,
            title: summary,
            repositoryID: repositoryID,
            request: EpicRequest(summary: summary, body: body, requestedAt: date, source: .app, attachmentCount: 0),
            stage: .request,
            questions: [],
            goal: nil,
            humanTasks: [],
            tasks: [],
            macID: nil,
            activities: [EpicActivity(kind: .writingQuestions, since: date)],
            blocker: nil,
            finalReview: nil,
            history: [Epic.HistoryEntry(date: date, text: "依頼しました")],
            updatedAt: date
        )
        state.epics.insert(epic, at: 0)
        schedule(after: 1.5) { [now] snapshot in
            let asked = now()
            snapshot.updateEpic(id) { epic in
                epic.stage = .questions
                epic.activities = []
                epic.questions = [
                    Question(
                        id: "Q1",
                        title: "最初に作る範囲",
                        why: "1 つの epic に収まるかが変わります",
                        options: [
                            DemoData.option("a", "いちばん小さい形から", "画面 1 つで確かめられる"),
                            DemoData.option("b", "依頼の全部", "タスクが多くなる")
                        ],
                        recommendedOptionID: "a",
                        recommendationReason: "早く手元で確かめられる",
                        askedAt: asked
                    )
                ]
                epic.log("質問を 1 つ作りました", at: asked)
            }
        }
        return id
    }
}
