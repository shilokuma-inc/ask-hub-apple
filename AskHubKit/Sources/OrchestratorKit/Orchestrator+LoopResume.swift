import Foundation

// 途中の epic の扱い（異常終了したループの再開・新しい epic の順番待ち）
extension Orchestrator {
    /// 担当リポジトリごとの制御用 worktree の epic（キーは `fullName` を小文字にしたもの）
    func epicSnapshots() async -> [String: EpicSnapshot] {
        var snapshots: [String: EpicSnapshot] = [:]
        for repository in config.repositories {
            snapshots[repository.fullName.lowercased()] = await runtime.epicSnapshot(of: repository)
        }
        return snapshots
    }

    func resumeStalledLoops(statuses: inout [String: LoopStatus]) async {
        for repository in config.repositories {
            await resumeIfStalled(repository, statuses: &statuses)
        }
    }

    private func resumeIfStalled(_ repository: RepositoryConfig, statuses: inout [String: LoopStatus]) async {
        let key = repository.fullName.lowercased()
        let status = statuses[key] ?? .idle
        guard status.stalled else {
            return
        }
        let snapshot = await runtime.epicSnapshot(of: repository)
        switch stallWatcher.update(repositoryKey: key, status: status, snapshot: snapshot) {
        case nil:
            return

        case let .giveUp(attempts):
            log("\(repository.fullName) のループが進まないまま \(attempts) 回止まったので、自動の再開をやめます（ループのログを確認してください）")

        case let .resume(attempt):
            do {
                // 再開では Discussion を伴わないので `{discussion}` は空になる
                try await runtime.launch(
                    config.loopCommand.render(for: repository),
                    environment: loopEnvironment(for: repository),
                    for: repository
                )
            } catch {
                // 同じポーリングで、途中の epic に新しい Discussion のループを被せない
                statuses[key] = LoopStatus(stateFileExists: true, processAlive: false, stalled: true)
                log("\(repository.fullName) の止まったループを再開できませんでした（\(attempt)/\(StallWatcher.maxAttempts) 回目）: \(error)")
                return
            }
            statuses[key] = LoopStatus(stateFileExists: false, processAlive: true)
            log("\(repository.fullName) のループがタスクを残して止まっていたので、再開しました（\(attempt)/\(StallWatcher.maxAttempts) 回目）")
        }
    }
}
