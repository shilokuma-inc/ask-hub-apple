import AskHubProtocol
import AskHubStateStore
import Foundation

/// タスクの流れが読み書きする状態のファイル（試行の結果・作業ブランチ・タスクの状態・仮決め）
extension TaskFlow {
    /// 成功した試行の `outputs`。当てた試行（ジョブの `attempts`）が成功していればそれを、違えば一覧から最後に成功した試行を読む
    func succeededOutputs(of job: JobFile) async throws(CommanderError) -> AttemptFile.Outputs? {
        let numbered = StatePath.attempt(job.repo, epic: job.epic, job: job.id, number: max(job.attempts, 1))
        if let attempt = try await context.readable(AttemptFile.self, at: numbered), attempt.job == job.id, attempt.outcome == .succeeded {
            return attempt.outputs
        }
        let entries: [DirectoryEntry]
        do {
            entries = try await context.store.listAll(StatePath.attempts(job.repo, epic: job.epic, job: job.id)) ?? []
        } catch {
            throw .store(error)
        }
        var latest: AttemptFile?
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
            guard let attempt = try await context.readable(AttemptFile.self, at: entry.path), attempt.job == job.id,
                  attempt.outcome == .succeeded, latest.map({ attempt.number > $0.number }) ?? true else { continue }
            latest = attempt
        }
        return latest?.outputs
    }

    /// 作業場所の用意が作った作業ブランチを `epic.json` に書く（`epic.json` は司令塔だけが書く）
    func writeBranch(_ branch: String, to epic: EpicFile) async throws(CommanderError) {
        let now = context.timestamp
        do {
            try await context.files.update(EpicFile.self, at: StatePath.epic(epic.repo, epic.id), message: "作業ブランチを書く") {
                guard $0.stage == .running, $0.branch == nil else { return false }
                $0.branch = branch
                $0.updatedAt = now
                return true
            }
        } catch {
            throw .files(error)
        }
    }

    /// ゴールのタスクの状態を変える（今の状態が `states` のどれかのときだけ）。変えた後のゴールを返す。
    /// 人が読むゴールの中身は変えないので、ゴールの版は上げない
    @discardableResult
    func setState(
        _ state: TaskState,
        of task: String,
        from states: Set<TaskState>,
        in epic: EpicFile
    ) async throws(CommanderError) -> GoalFile {
        do {
            let path = StatePath.goal(epic.repo, epic.id)
            return try await context.files.update(GoalFile.self, at: path, message: "タスク \(task) を \(state.rawValue) にする") { goal in
                guard let index = goal.tasks.firstIndex(where: { $0.id == task }), states.contains(goal.tasks[index].state) else {
                    return false
                }
                goal.tasks[index].state = state
                return true
            }.file
        } catch {
            throw .files(error)
        }
    }

    /// 実装・直しで Claude が報告した仮決めを `decisions.json` に足す（見える・内部の区分は、後でレビュー役が決める）
    func addDecisions(
        _ decisions: [TaskOutputReport.Decision],
        task: String,
        pullRequest: Int,
        epic: EpicFile
    ) async throws(CommanderError) {
        guard !decisions.isEmpty else { return }
        let path = StatePath.decisions(epic.repo, epic.id)
        let message = "タスク \(task) の仮決めを足す"
        do {
            if try await context.files.read(DecisionsFile.self, at: path) == nil {
                do {
                    let file = DecisionsFile().adding(decisions, task: task, pullRequest: pullRequest)
                    try await context.files.create(file, at: path, message: message)
                    return
                } catch .alreadyExists {
                    // 読んだ後に作られた。下で足す
                }
            }
            try await context.files.update(DecisionsFile.self, at: path, message: message) { file in
                let next = file.adding(decisions, task: task, pullRequest: pullRequest)
                guard next != file else { return false }
                file = next
                return true
            }
        } catch {
            throw .files(error)
        }
    }
}

extension DecisionsFile {
    /// 仮決めを足す。同じタスク・同じ子 PR の同じ仮決め（やり直しで 2 度足すもの）は足さない。id は `d<番号>` で続ける
    func adding(_ decisions: [TaskOutputReport.Decision], task: String, pullRequest: Int) -> Self {
        var file = self
        var number = items.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        for decision in decisions {
            let item = Item(
                id: "",
                task: task,
                pullRequest: pullRequest,
                what: decision.what,
                why: decision.why,
                alternatives: decision.alternatives
            )
            guard !file.items.contains(where: { $0.sameDecision(as: item) }) else { continue }
            number += 1
            var added = item
            added.id = "d\(number)"
            file.items.append(added)
        }
        return file
    }
}

extension DecisionsFile.Item {
    /// 同じタスク・子 PR の、同じ中身の仮決めか（id・区分・スクショ・答えは比べない）
    func sameDecision(as other: Self) -> Bool {
        task == other.task && pullRequest == other.pullRequest && what == other.what && why == other.why
            && alternatives == other.alternatives
    }
}
