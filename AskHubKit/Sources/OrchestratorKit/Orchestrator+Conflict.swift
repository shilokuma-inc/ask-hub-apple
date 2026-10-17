import AskHubKit
import Foundation

// epic の最終 PR が既定ブランチとコンフリクトしたら、conflictCommand（askhub-resolve-conflict）に解消させる。
// AskHub のアプリからはマージも解消もできないため
extension Orchestrator {
    /// 解消させるコマンドの制限時間。ビルドと検証を含むので長めにとる
    static let conflictCommandTimeout: Duration = .seconds(30 * 60)

    /// ポーリングの最後に行うこと。epic の最終 PR が既定ブランチとコンフリクトしていたら裏で解消させ（終わるのは待たない）、
    /// ループの状態を状態用の Issue に書き出す
    func finishPoll(statuses: [String: LoopStatus]) async {
        await startConflictResolutions()
        // 同じリポジトリではコンフリクトの解消を先に始め、第三者レビュー・修正はその後に空いているリポジトリで始める
        await startFinalReviews()
        await publishLoopStatuses(statuses: statuses)
        // 状態用の Issue を読み直した後に、手動ループの完了を見る
        await finalizeEpicsFromGitHub(statuses: statuses)
    }

    /// コンフリクトした最終 PR を探し、解消を裏で始める。
    /// 解消は最長 30 分かかるので、ポーリングを止めないよう終わるのを待たない。同じリポジトリでは 1 件ずつ、別のリポジトリは並列に解消する
    func startConflictResolutions() async {
        guard activeUsageLimit(at: now()) == nil else {
            return
        }
        let pullRequests: [ConflictingPullRequest]
        do {
            pullRequests = try await github.conflictingEpicFinalPullRequests(orgs: config.orgs)
        } catch {
            log("コンフリクトした最終 PR を確認できませんでした: \(error)")
            return
        }
        conflictingPullRequests = pullRequests
        conflictTracker.prune(keeping: pullRequests)
        startConflictResolutions(among: pullRequests)
    }

    /// 裏で実行中の解消と、最終 PR の第三者レビュー・修正がすべて終わるまで待つ（`--once` で終わる前・`run` の終わりなど）。
    /// 子プロセスはオーケストレーターの終了で止まらないので、結果を PR にコメントしてから終わる。
    /// 待っている間は新しい解消・レビュー・修正を始めない（同じリポジトリの次の PR は、次のポーリングで始める）
    public func waitForConflictResolutions() async {
        drainsConflictResolutions = true
        defer { drainsConflictResolutions = false }
        while let task = conflictResolutions.values.first ?? finalReviews.values.first {
            await task.value
        }
    }

    /// 取得済みの一覧から、始められる解消を裏で始める
    func startConflictResolutions(among pullRequests: [ConflictingPullRequest]) {
        guard activeUsageLimit(at: now()) == nil, !drainsConflictResolutions else {
            return
        }
        // 第三者レビュー・修正を実行中のリポジトリでは始めない（同じ checkout に一時 worktree を作るため）
        let busy = finalReviewRepositories
        let available = pullRequests.filter { !busy.contains($0.repository.lowercased()) }
        for (pullRequest, repository) in conflictTracker.startable(in: available, config: config) {
            let key = pullRequest.repository.lowercased()
            conflictTracker.start(pullRequest)
            conflictResolutions[key] = Task {
                await resolveConflict(of: pullRequest, in: repository)
                conflictTracker.finish(pullRequest)
                conflictResolutions[key] = nil
                // 同じリポジトリでほかの最終 PR もコンフリクトしていれば、次のポーリングを待たずに始める
                // （一覧は最後に取得したもの。古くても、同じ組み合わせは試し直さず、スクリプトが取得し直してから取り込む）。
                // 今終わった PR は push で head が変わっているので、古い一覧の組み合わせでは試し直さず、次のポーリングで取得し直す
                startConflictResolutions(among: conflictingPullRequests.filter { $0.key != pullRequest.key })
                // 同じリポジトリで待たせていた第三者レビュー・修正も、解消の後に始める
                startFinalReviews(among: finalReviewCandidates)
            }
        }
    }

    private func resolveConflict(of pullRequest: ConflictingPullRequest, in repository: RepositoryConfig) async {
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        log("\(name)（\(pullRequest.headBranch) → \(pullRequest.baseBranch)）がコンフリクトしているので、解消させます")
        let output: String
        do {
            let result = try await runtime.run(
                config.conflictCommand.render(for: repository, pullRequest: pullRequest),
                input: "",
                environment: config.claudeEnvironment,
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
            // 人間・ループと同じアカウントで書くので、目印で最終 PR への指示と見分けさせる（docs/protocol.md の「最終 PR への指示」）
            try await github.comment(
                onPullRequest: pullRequest.number,
                in: pullRequest.repository,
                body: "\(FinalPullRequestMarker.orchestrator)\n\(body)"
            )
        } catch {
            log("\(name) に結果をコメントできませんでした: \(error)")
        }
    }
}
