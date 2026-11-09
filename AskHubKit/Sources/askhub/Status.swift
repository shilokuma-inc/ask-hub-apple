import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation

extension AskHubMain {
    /// epic・質問・ゴール・着手前の確認の結果と、送った意図の処理の結果を出す
    static func status(_ arguments: CommandArguments) async throws {
        try arguments.only(["repo"])
        let connection = try connection()
        let (key, store) = (connection.key, connection.store)
        let files = StateFileStore(store: store)
        let repos: [RepositoryFullName]
        if arguments.values["repo"] != nil {
            repos = [try arguments.repository()]
        } else {
            var found: [RepositoryFullName] = []
            for owner in try await directories(StatePath.repositories, in: store) {
                for name in try await directories("\(StatePath.repositories)/\(owner)", in: store) {
                    if let repo = RepositoryFullName(rawValue: "\(owner)/\(name)") { found.append(repo) }
                }
            }
            repos = found
        }
        for repo in repos {
            print("■ \(repo.rawValue)")
            for name in try await directories(StatePath.epics(repo), in: store) {
                guard let id = ULID(rawValue: name) else { continue }
                try await printEpic(id, of: repo, files: files)
            }
        }
        try await printConsumed(of: key.keyID, store: store, files: files)
    }

    private static func printEpic(_ id: ULID, of repo: RepositoryFullName, files: StateFileStore) async throws {
        guard let epic = try await files.read(EpicFile.self, at: StatePath.epic(repo, id))?.file else { return }
        print("  epic \(id.rawValue)「\(epic.title)」 段階: \(epic.stage.rawValue)\(epic.mac.map { " Mac: \($0)" } ?? "")")
        if let pause = epic.pause { print("    一時停止中（\(pause.since) から。再開: askhub resume --repo \(repo.rawValue) --epic \(id.rawValue)）") }
        if let summary = epic.summary { print("    要約: \(summary)") }
        // 答え直しもできるよう、要らなくなった質問のほかはすべて出す
        let questions = try await files.read(QuestionsFile.self, at: StatePath.questions(repo, id))?.file.questions ?? []
        for question in questions where question.state != .dropped {
            printQuestion(question)
        }
        if let readiness = try await files.read(ReadinessFile.self, at: StatePath.readiness(repo, id))?.file {
            let split = readiness.split.map(\.title).joined(separator: " / ")
            let line = "    着手前の確認（版 \(readiness.version)）: \(readiness.verdict.rawValue) \(readiness.reason)"
            print(line + (split.isEmpty ? "" : " 分け方: \(split)"))
        }
        if let goal = try await files.read(GoalFile.self, at: StatePath.goal(repo, id))?.file { printGoal(goal) }
        try await printWaitingJobs(of: epic, files: files)
    }

    /// 人の対応を待っているジョブと、最後の試行の失敗を出す（やり直す・やめるに渡す番号つき）
    private static func printWaitingJobs(of epic: EpicFile, files: StateFileStore) async throws {
        for entry in try await files.store.listAll(StatePath.jobs(epic.repo, epic: epic.id)) ?? [] where entry.kind == .file {
            // 読めないジョブは、人の対応待ちかどうか分からないので、見落とさないよう出す
            let job: JobFile
            do {
                guard let read = try await files.read(JobFile.self, at: entry.path)?.file else { continue }
                job = read
            } catch {
                print("    読めないジョブ \(entry.name)（\(error)）")
                continue
            }
            guard job.state == .waitingHuman else { continue }
            print("    人の対応待ちのジョブ \(job.kind.rawValue) \(job.id.rawValue)（試行 \(job.attempts)）")
            let path = StatePath.attempt(epic.repo, epic: epic.id, job: job.id, number: job.attempts)
            do {
                if let failure = try await files.read(AttemptFile.self, at: path)?.file.failure {
                    print("      失敗: \(failure.failureClass.rawValue) \(failure.message)")
                }
            } catch {
                print("      失敗の理由を読めない（\(error)）")
            }
            let target = "--repo \(epic.repo.rawValue) --epic \(epic.id.rawValue) --job \(job.id.rawValue) --attempt \(job.attempts)"
            print("      やり直す: askhub retry \(target)\n      やめる: askhub give-up \(target)")
        }
    }

    /// 答えるのに要るもの（なぜ・選択肢ごとの変化・推奨と理由・慎重に決めてほしい理由・今の回答）を出す
    private static func printQuestion(_ question: QuestionsFile.Question) {
        print("    \(question.id)（版 \(question.version)・\(question.state.rawValue)）\(question.title)")
        if let caution = question.caution { print("      ⚠️ 慎重に決めてほしい（\(caution.kind.rawValue)）: \(caution.reason)") }
        print("      なぜ: \(question.why)")
        for option in question.options { print("      - \(option.label): \(option.effect)") }
        print("      推奨: \(question.recommended)（\(question.reason)）")
        if !question.dependsOn.isEmpty { print("      前提: \(question.dependsOn.joined(separator: "・"))") }
        if let answer = question.answer {
            print("      回答: \(answer.choice ?? "（自由記述）")" + (answer.note.isEmpty ? "" : " / \(answer.note)"))
        }
        if let explanation = question.explanations.last?.text { print("      説明: \(explanation)") }
    }

    /// 開始する前に確かめるもの（要約・決まったこと・やらないこと・完了の条件・タスク・人がする作業）を出す
    private static func printGoal(_ goal: GoalFile) {
        print("    ゴール（版 \(goal.version)）: \(goal.summary)")
        for item in goal.decided { print("      決まったこと \(item.question): \(item.text)") }
        for item in goal.outOfScope { print("      やらないこと: \(item)") }
        for item in goal.doneWhen { print("      完了の条件: \(item)") }
        for task in goal.tasks {
            let premise = task.dependsOn.isEmpty ? "" : "（前提: \(task.dependsOn.joined(separator: "・"))）"
            print("      タスク \(task.id): \(task.title)" + premise)
            if let detail = task.detail, !detail.isEmpty { print("        \(detail)") }
        }
        for task in goal.humanTasks { print("      人がする作業 \(task.id): \(task.title)（\(task.why)）") }
        for note in goal.notApplied ?? [] { print("      反映しなかった指示: \(note)") }
    }

    /// 送った意図の処理の結果（新しい順に 10 件）
    private static func printConsumed(of key: KeyID, store: any StateStore, files: StateFileStore) async throws {
        let entries = try await store.listAll("\(StatePath.consumedDirectory)/\(key.rawValue)") ?? []
        let recent = entries.filter { $0.kind == .file }.sorted { $0.name > $1.name }.prefix(10)
        guard !recent.isEmpty else { return }
        print("■ 送った意図の処理の結果")
        for entry in recent {
            guard let consumed = try await files.read(ConsumedIntentFile.self, at: entry.path)?.file else { continue }
            let line = "  \(entry.name.dropLast(".json".count)) \(consumed.kind): \(consumed.result.rawValue)"
            print(line + (consumed.reason.map { "（\($0)）" } ?? ""))
        }
    }

    private static func directories(_ path: String, in store: any StateStore) async throws -> [String] {
        try await store.listAll(path)?.filter { $0.kind == .directory }.map(\.name).sorted() ?? []
    }
}
