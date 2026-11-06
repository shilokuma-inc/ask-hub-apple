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
        print("  epic \(id.rawValue)「\(epic.title)」 段階: \(epic.stage.rawValue)")
        if let summary = epic.summary { print("    要約: \(summary)") }
        if let questions = try await files.read(QuestionsFile.self, at: StatePath.questions(repo, id))?.file {
            for question in questions.questions where !question.state.isSettled {
                let options = question.options.map(\.label).joined(separator: " / ")
                print("    \(question.id)（版 \(question.version)・\(question.state.rawValue)）\(question.title)")
                print("      選択肢: \(options)（推奨: \(question.recommended)）")
                if let explanation = question.explanations.last?.text { print("      説明: \(explanation)") }
            }
        }
        if let readiness = try await files.read(ReadinessFile.self, at: StatePath.readiness(repo, id))?.file {
            let split = readiness.split.map(\.title).joined(separator: " / ")
            let line = "    着手前の確認（版 \(readiness.version)）: \(readiness.verdict.rawValue) \(readiness.reason)"
            print(line + (split.isEmpty ? "" : " 分け方: \(split)"))
        }
        if let goal = try await files.read(GoalFile.self, at: StatePath.goal(repo, id))?.file {
            print("    ゴール（版 \(goal.version)）: \(goal.summary)（タスク \(goal.tasks.count) 個）")
            for note in goal.notApplied ?? [] { print("      反映しなかった指示: \(note)") }
        }
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
