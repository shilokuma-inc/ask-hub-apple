import Foundation

// epic の最終 PR が既定ブランチとコンフリクトしたら、conflictCommand（askhub-resolve-conflict）に解消させる。
// AskHub のアプリからはマージも解消もできないため
extension Orchestrator {
    /// 解消させるコマンドの制限時間。ビルドと検証を含むので長めにとる
    static let conflictCommandTimeout: Duration = .seconds(30 * 60)

    /// ポーリングの最後に行うこと。epic の最終 PR が既定ブランチとコンフリクトしていたら解消させ（1 回のポーリングで 1 件）、
    /// ループの状態を状態用の Issue に書き出す
    func finishPoll(statuses: [String: LoopStatus]) async {
        await resolveConflictingFinalPullRequest()
        await publishLoopStatuses(statuses: statuses)
    }

    func resolveConflictingFinalPullRequest() async {
        guard activeUsageLimit(at: now()) == nil else {
            return
        }
        let pullRequests: [ConflictingPullRequest]
        do {
            pullRequests = try await github.conflictingEpicFinalPullRequests(org: config.org)
        } catch {
            log("コンフリクトした最終 PR を確認できませんでした: \(error)")
            return
        }
        conflictTracker.prune(keeping: pullRequests)
        guard let (pullRequest, repository) = conflictTracker.next(in: pullRequests, config: config) else {
            return
        }
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        log("\(name)（\(pullRequest.headBranch) → \(pullRequest.baseBranch)）がコンフリクトしているので、解消させます")
        let output: String
        do {
            let result = try await runtime.run(
                config.conflictCommand.render(for: repository, pullRequest: pullRequest),
                input: "",
                for: repository,
                timeout: Self.conflictCommandTimeout
            )
            output = result.output
        } catch {
            await record(.unresolved(reason: "conflictCommand を起動できませんでした（\(error)）"), for: pullRequest)
            return
        }
        // 利用上限で終わったなら、試したことにせず解除を待つ
        if recordUsageLimit(in: output) {
            log("\(name) のコンフリクトを解消する claude が利用上限で終わりました。解除の後に試し直します")
            return
        }
        let outcome = ConflictTracker.outcome(in: output) ?? .unresolved(reason: "コマンドの出力から結果を読み取れませんでした")
        await record(outcome, for: pullRequest)
    }

    private func record(_ outcome: ConflictTracker.Outcome, for pullRequest: ConflictingPullRequest) async {
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        let gaveUp = conflictTracker.record(outcome, for: pullRequest)
        let body: String
        switch outcome {
        case .merged:
            log("\(name) に \(pullRequest.baseBranch) を取り込みました（コンフリクトはありませんでした）")
            body = """
                \(pullRequest.baseBranch) を \(pullRequest.headBranch) に取り込みました（手元ではコンフリクトしませんでした）。
                CI が通ってからマージしてください。（askhub-orchestrator）
                """

        case .resolved:
            log("\(name) の \(pullRequest.baseBranch) とのコンフリクトを解消しました")
            body = """
                \(pullRequest.baseBranch) とのコンフリクトを解消し、\(pullRequest.headBranch) に push しました。
                マージコミットで解消の内容を確認し、CI が通ってからマージしてください。（askhub-orchestrator）
                """

        case let .unresolved(reason):
            log("\(name) のコンフリクトを解消できませんでした（\(gaveUp ? "あきらめます" : "組み合わせが変わったら試し直します")）: \(reason)")
            let stop = gaveUp ? "\(ConflictTracker.maxFailures) 回続けて解消できなかったので、自動の解消はやめます。" : ""
            body = """
                \(pullRequest.baseBranch) とのコンフリクトを自動で解消できませんでした: \(reason)
                \(stop)手元で \(pullRequest.headBranch) に \(pullRequest.baseBranch) を取り込んで解消してください。（askhub-orchestrator）
                """
        }
        do {
            try await github.comment(onPullRequest: pullRequest.number, in: pullRequest.repository, body: body)
        } catch {
            log("\(name) に結果をコメントできませんでした: \(error)")
        }
    }
}
