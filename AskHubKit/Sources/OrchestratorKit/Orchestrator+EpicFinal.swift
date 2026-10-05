import AskHubKit
import Foundation

// epic の最終 PR・起動済みの Discussion の追跡
extension Orchestrator {
    /// 完了した epic の最終 PR を作る。完了しているのに作り終えられなかった担当リポジトリ（`fullName` を小文字にしたもの）を返す
    func finalizeCompletedEpics(statuses: [String: LoopStatus]) async -> Set<String> {
        var unfinalized: Set<String> = []
        for repository in config.repositories
        where await finalizeEpicIfComplete(repository, status: statuses[repository.fullName.lowercased()] ?? .idle) {
            unfinalized.insert(repository.fullName.lowercased())
        }
        return unfinalized
    }

    func advanceLaunchedDiscussions(
        _ discussions: [ReadyDiscussion],
        statuses: [String: LoopStatus],
        snapshots: [String: EpicSnapshot]
    ) async {
        // 再起動で追跡が消えても、制御用 worktree がその Discussion から準備を終えていれば、ループは始まっている。
        // ラベルを残すと、epic が終わった後に同じ Discussion から同じ epic をもう一度始めてしまう
        for discussion in discussions {
            guard let repository = config.repository(named: discussion.repository) else {
                continue
            }
            let key = repository.fullName.lowercased()
            if let snapshot = snapshots[key], snapshot.loopPrepared, snapshot.discussion == discussion.number {
                tracker.adoptStarted(discussion, repositoryKey: key)
            }
        }
        let actions = tracker.update(
            discussions: discussions,
            statuses: statuses,
            preparedDiscussions: snapshots.compactMapValues(\.discussion)
        )
        for action in actions {
            await perform(action)
        }
    }

    /// 完了した epic の最終 PR を作る。完了しているのに作り終えられなかった（次のポーリングで再試行する）ときは `true`
    private func finalizeEpicIfComplete(_ repository: RepositoryConfig, status: LoopStatus) async -> Bool {
        let snapshot = await runtime.epicSnapshot(of: repository)
        guard case let .complete(branch, summary) = EpicCompletion(snapshot: snapshot, status: status) else {
            return false
        }
        // 同じ epic の PR は 1 回だけ作る。ブランチが変われば（次の epic）改めて判定する
        let key = "\(repository.fullName.lowercased()) \(branch)"
        guard !finalizedEpics.contains(key) else {
            return false
        }
        do {
            // 閉じた PR もあれば作り直さない（人がマージせずに閉じたものを復活させない）
            if let existing = try await github.existingPullRequest(in: repository.fullName, head: branch) {
                // 作った後にラベルだけ付け損ねた場合に備え、open な PR には付け直す（付与は冪等）
                if existing.isOpen {
                    let rewritten = try await rewriteFinalPullRequestIfResumed(
                        existing,
                        key: key,
                        summary: summary,
                        snapshot: snapshot,
                        in: repository
                    )
                    if !rewritten, let discussion = snapshot.discussion,
                       !EpicSnapshot.hasDiscussionMarker(existing.body, discussion: discussion) {
                        // 目印を入れる前のオーケストレーターが作った PR などには、ゴール元の Discussion の目印を足す。
                        // 足さないと、マージしても Discussion が閉じない（書き直した本文には目印が入っている）
                        let body = EpicSnapshot.pullRequestBody(summary: existing.body ?? "", discussion: discussion)
                        try await github.updatePullRequestBody(in: repository.fullName, number: existing.number, body: body)
                        log("\(repository.fullName) の最終 PR #\(existing.number) に、ゴール元の Discussion #\(discussion) の目印を足しました")
                    }
                    try await github.addEpicFinalLabel(in: repository.fullName, number: existing.number)
                }
                finalizedEpics.insert(key)
                return false
            }
            let body = EpicSnapshot.pullRequestBody(summary: summary, discussion: snapshot.discussion)
            let number = try await github.createEpicFinalPullRequest(in: repository.fullName, head: branch, body: body)
            log("\(repository.fullName) の \(branch) が完了したので、最終 PR #\(number) を作りました")
            // ラベルの付与に失敗しても、次のポーリングで既存の PR として付け直す
            try await github.addEpicFinalLabel(in: repository.fullName, number: number)
            finalizedEpics.insert(key)
            log("\(repository.fullName) の最終 PR #\(number) に epic-final を付けました")
            return false
        } catch {
            log("\(repository.fullName) の \(branch) の最終 PR を作れませんでした（次のポーリングで再試行します）: \(error)")
            return true
        }
    }
}
