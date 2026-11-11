import AskHubProtocol
import AskHubStateStore
import Foundation

/// 非常口の `askhub status` が出す中身。epic・質問・ゴール・着手前の確認の結果・人の対応待ちのジョブと、送った意図の処理の結果
public struct StatusReport: Sendable {
    let files: StateFileStore
    private var lines: [String] = []

    init(files: StateFileStore) {
        self.files = files
    }

    /// `repository` が nil なら、状態リポジトリにあるすべてのリポジトリを出す。`device` は送った意図の処理の結果を読む端末の鍵。
    ///
    /// 1 回で多くのファイルを読むので、写し（`snapshot()`）から読む。無いファイルは tree で分かるので取りに行かない（GitHub は 404 も上限に数える）。
    /// 同じ `store` で読み直すと、変わっていない tree と blob は取りに行かない
    public static func render(_ store: any StateStore, repository: RepositoryFullName?, device: KeyID) async throws -> String {
        var report = StatusReport(files: StateFileStore(store: try await store.snapshot()))
        let repos: [RepositoryFullName]
        if let repository {
            repos = [repository]
        } else {
            var found: [RepositoryFullName] = []
            for owner in try await report.directories(StatePath.repositories) {
                for name in try await report.directories("\(StatePath.repositories)/\(owner)") {
                    if let repo = RepositoryFullName(rawValue: "\(owner)/\(name)") { found.append(repo) }
                }
            }
            repos = found
        }
        for repo in repos {
            report.add("■ \(repo.rawValue)")
            for name in try await report.directories(StatePath.epics(repo)) {
                guard let id = ULID(rawValue: name) else { continue }
                try await report.addEpic(id, of: repo)
            }
        }
        try await report.addConsumed(of: device)
        return report.lines.joined(separator: "\n")
    }

    private mutating func add(_ line: String) {
        lines.append(line)
    }

    private mutating func addEpic(_ id: ULID, of repo: RepositoryFullName) async throws {
        guard let epic = try await files.read(EpicFile.self, at: StatePath.epic(repo, id))?.file else { return }
        add("  epic \(id.rawValue)「\(epic.title)」 段階: \(epic.stage.rawValue)\(epic.mac.map { " Mac: \($0)" } ?? "")")
        if let pause = epic.pause { add("    一時停止中（\(pause.since) から。再開: askhub resume --repo \(repo.rawValue) --epic \(id.rawValue)）") }
        if let summary = epic.summary { add("    要約: \(summary)") }
        // 答え直しもできるよう、要らなくなった質問のほかはすべて出す
        let questions = try await files.read(QuestionsFile.self, at: StatePath.questions(repo, id))?.file.questions ?? []
        for question in questions where question.state != .dropped {
            addQuestion(question)
        }
        if let readiness = try await files.read(ReadinessFile.self, at: StatePath.readiness(repo, id))?.file {
            let split = readiness.split.map(\.title).joined(separator: " / ")
            let line = "    着手前の確認（版 \(readiness.version)）: \(readiness.verdict.rawValue) \(readiness.reason)"
            add(line + (split.isEmpty ? "" : " 分け方: \(split)"))
        }
        if let goal = try await files.read(GoalFile.self, at: StatePath.goal(repo, id))?.file { addGoal(goal) }
        try await addWaitingJobs(of: epic)
    }

    /// 人の対応を待っているジョブと、最後の試行の失敗を出す（やり直す・やめるに渡す番号つき）
    private mutating func addWaitingJobs(of epic: EpicFile) async throws {
        for entry in try await files.store.listAll(StatePath.jobs(epic.repo, epic: epic.id)) ?? [] where entry.kind == .file {
            // 読めないジョブは、人の対応待ちかどうか分からないので、見落とさないよう出す
            let job: JobFile
            do {
                guard let read = try await files.read(JobFile.self, at: entry.path)?.file else { continue }
                job = read
            } catch {
                add("    読めないジョブ \(entry.name)（\(error)）")
                continue
            }
            guard job.state == .waitingHuman else { continue }
            add("    人の対応待ちのジョブ \(job.kind.rawValue) \(job.id.rawValue)（試行 \(job.attempts)）")
            let path = StatePath.attempt(epic.repo, epic: epic.id, job: job.id, number: job.attempts)
            do {
                if let failure = try await files.read(AttemptFile.self, at: path)?.file.failure {
                    add("      失敗: \(failure.failureClass.rawValue) \(failure.message)")
                }
            } catch {
                add("      失敗の理由を読めない（\(error)）")
            }
            let target = "--repo \(epic.repo.rawValue) --epic \(epic.id.rawValue) --job \(job.id.rawValue) --attempt \(job.attempts)"
            add("      やり直す: askhub retry \(target)")
            add("      やめる: askhub give-up \(target)")
        }
    }

    /// 答えるのに要るもの（なぜ・選択肢ごとの変化・推奨と理由・慎重に決めてほしい理由・今の回答）を出す
    private mutating func addQuestion(_ question: QuestionsFile.Question) {
        add("    \(question.id)（版 \(question.version)・\(question.state.rawValue)）\(question.title)")
        if let caution = question.caution { add("      ⚠️ 慎重に決めてほしい（\(caution.kind.rawValue)）: \(caution.reason)") }
        add("      なぜ: \(question.why)")
        for option in question.options { add("      - \(option.label): \(option.effect)") }
        add("      推奨: \(question.recommended)（\(question.reason)）")
        if !question.dependsOn.isEmpty { add("      前提: \(question.dependsOn.joined(separator: "・"))") }
        if let answer = question.answer {
            add("      回答: \(answer.choice ?? "（自由記述）")" + (answer.note.isEmpty ? "" : " / \(answer.note)"))
        }
        if let explanation = question.explanations.last?.text { add("      説明: \(explanation)") }
    }

    /// 開始する前に確かめるもの（要約・決まったこと・やらないこと・完了の条件・タスク・人がする作業）を出す
    private mutating func addGoal(_ goal: GoalFile) {
        add("    ゴール（版 \(goal.version)）: \(goal.summary)")
        for item in goal.decided { add("      決まったこと \(item.question): \(item.text)") }
        for item in goal.outOfScope { add("      やらないこと: \(item)") }
        for item in goal.doneWhen { add("      完了の条件: \(item)") }
        for task in goal.tasks {
            let premise = task.dependsOn.isEmpty ? "" : "（前提: \(task.dependsOn.joined(separator: "・"))）"
            add("      タスク \(task.id): \(task.title)" + premise)
            if let detail = task.detail, !detail.isEmpty { add("        \(detail)") }
        }
        for task in goal.humanTasks { add("      人がする作業 \(task.id): \(task.title)（\(task.why)）") }
        for note in goal.notApplied ?? [] { add("      反映しなかった指示: \(note)") }
    }

    /// 送った意図の処理の結果（新しい順に 10 件）
    private mutating func addConsumed(of key: KeyID) async throws {
        let entries = try await files.store.listAll("\(StatePath.consumedDirectory)/\(key.rawValue)") ?? []
        let recent = entries.filter { $0.kind == .file }.sorted { $0.name > $1.name }.prefix(10)
        guard !recent.isEmpty else { return }
        add("■ 送った意図の処理の結果")
        for entry in recent {
            guard let consumed = try await files.read(ConsumedIntentFile.self, at: entry.path)?.file else { continue }
            let line = "  \(entry.name.dropLast(".json".count)) \(consumed.kind): \(consumed.result.rawValue)"
            add(line + (consumed.reason.map { "（\($0)）" } ?? ""))
        }
    }

    private func directories(_ path: String) async throws -> [String] {
        try await files.store.listAll(path)?.filter { $0.kind == .directory }.map(\.name).sorted() ?? []
    }
}
