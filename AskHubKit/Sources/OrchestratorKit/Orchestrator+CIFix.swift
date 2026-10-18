import AskHubKit
import Foundation

// epic の最終 PR の CI が失敗していたら、ciFixCommand（askhub-fix-ci）に失敗したジョブのログを読ませて直させる。
// epic が完了した後はループが終わっているので、放っておくと失敗したまま残る
extension Orchestrator {
    /// 直させるコマンドの制限時間。ビルドと検証を含むので長めにとる
    static let ciFixCommandTimeout: Duration = .seconds(30 * 60)

    /// CI が失敗した最終 PR を探し、直させるのを裏で始める（終わるのは待たない）。
    /// 同じ PR の同じ head のコミットでは 1 回だけ、PR ごとに `CIFixTracker.maxAttempts` 回まで試す。
    /// 同じリポジトリではコンフリクトの解消と合わせて 1 件ずつ、別のリポジトリは並列に直させる
    func startCIFixes(statuses: [String: LoopStatus]) async {
        guard activeUsageLimit(at: now()) == nil, !drainsConflictResolutions else {
            return
        }
        let pullRequests: [FailingPullRequest]
        do {
            pullRequests = try await github.failingEpicFinalPullRequests(orgs: config.orgs, trust: trust)
        } catch {
            log("CI が失敗した最終 PR を確認できませんでした: \(error)")
            return
        }
        ciFixTracker.prune(keeping: pullRequests)
        for pullRequest in pullRequests {
            guard let repository = config.repository(named: pullRequest.repository),
                  await isIdle(repository, for: pullRequest, statuses: statuses),
                  await loadCIFixHistory(of: pullRequest) else {
                continue
            }
            switch ciFixTracker.decision(for: pullRequest) {
            case .skip:
                continue

            case .giveUp:
                await giveUpCIFix(of: pullRequest)

            case .start:
                await startCIFix(of: pullRequest, in: repository)
            }
        }
    }

    /// そのリポジトリで、ほかの解消・修正もループの作業もしていないか。
    /// ループが同じ epic ブランチで動いている（・再開を待っている）間は、ループの push とぶつかるので直させない
    private func isIdle(_ repository: RepositoryConfig, for pullRequest: FailingPullRequest, statuses: [String: LoopStatus]) async -> Bool {
        let key = repository.fullName.lowercased()
        guard ciFixes[key] == nil, conflictResolutions[key] == nil, !conflictTracker.isRunning(in: key),
              pendingInstructionResumes[key] == nil else {
            return false
        }
        let status = statuses[key] ?? LoopStatus(stateFileExists: nil, processAlive: false)
        guard status.processAlive || status.stateFileExists != false else {
            return true
        }
        return await runtime.epicSnapshot(of: repository).branch != pullRequest.headBranch
    }

    /// 初めて見た PR は、コメントから試した記録を読む。読めなければ今回は見送る
    private func loadCIFixHistory(of pullRequest: FailingPullRequest) async -> Bool {
        guard ciFixTracker.needsHistory(of: pullRequest) else {
            return true
        }
        do {
            let comments = try await github.comments(in: pullRequest.repository, issue: pullRequest.number)
            ciFixTracker.loadHistory(from: comments, for: pullRequest)
            return true
        } catch {
            log("\(pullRequest.repository)#\(pullRequest.number) のコメントを読めないので、CI の修正は次のポーリングで試します: \(error)")
            return false
        }
    }

    private func startCIFix(of pullRequest: FailingPullRequest, in repository: RepositoryConfig) async {
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        let key = pullRequest.repository.lowercased()
        // コメントを書く間（await）にほかの修正を始めないよう、先に始めたことにする
        ciFixTracker.start(pullRequest)
        let attempt = ciFixTracker.histories[pullRequest.key]?.attemptedSHAs.count ?? 1
        let posted = await commentOnFailingPullRequest(pullRequest, body: """
            \(CIFixTracker.attemptMarker(pullRequest.headSHA))
            \(pullRequest.headSHA.prefix(7)) で CI が失敗しているので、失敗したジョブのログを読ませて直させます\
            （\(attempt) / \(CIFixTracker.maxAttempts) 回目）。（askhub-orchestrator）
            """)
        // 試したことを PR に残せなければ、再起動の後に同じコミットで二重に直させかねないので始めない
        guard posted else {
            ciFixTracker.cancel(pullRequest)
            ciFixTracker.finish(pullRequest)
            return
        }
        log("\(name)（\(pullRequest.headBranch) の \(pullRequest.headSHA.prefix(7))）の CI が失敗しているので、直させます")
        ciFixes[key] = Task {
            await fixCI(of: pullRequest, in: repository)
            ciFixTracker.finish(pullRequest)
            ciFixes[key] = nil
        }
    }

    private func fixCI(of pullRequest: FailingPullRequest, in repository: RepositoryConfig) async {
        let output: String
        do {
            let result = try await runtime.run(
                config.ciFixCommand.render(for: repository, pullRequest: pullRequest),
                input: "",
                environment: config.claudeEnvironment,
                for: repository,
                timeout: Self.ciFixCommandTimeout
            )
            output = result.output
        } catch {
            await record(.unresolved(reason: "ciFixCommand を起動できませんでした（\(error)）"), for: pullRequest)
            return
        }
        // 利用上限で終わったなら、試したことにせず解除を待つ
        if recordUsageLimit(in: output) {
            log("\(pullRequest.repository)#\(pullRequest.number) の CI を直す claude が利用上限で終わりました。解除の後に試し直します")
            await cancelCIFix(of: pullRequest, reason: "Claude の利用上限で止まったので、解除の後に試し直します")
            return
        }
        let outcome = CIFixTracker.outcome(in: output) ?? .unresolved(reason: "コマンドの出力から結果を読み取れませんでした")
        await record(outcome, for: pullRequest)
    }

    private func record(_ outcome: CIFixTracker.Outcome, for pullRequest: FailingPullRequest) async {
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        switch outcome {
        case .fixed:
            log("\(name) の CI の失敗を直し、\(pullRequest.headBranch) に push しました")
            await commentOnFailingPullRequest(pullRequest, body: """
                CI の失敗を直し、\(pullRequest.headBranch) に push しました。
                直した内容を確認し、CI が通ってからマージしてください。（askhub-orchestrator）
                """)

        case .stale:
            log("\(name) の \(pullRequest.headBranch) が直させる前に更新されていたので、この head では試したことにしません")
            await cancelCIFix(of: pullRequest, reason: "直させる前に \(pullRequest.headBranch) が更新されていたので、この試行は数えません")

        case let .unresolved(reason):
            let gaveUp = ciFixTracker.reachedLimit(pullRequest)
            log("\(name) の CI の失敗を直せませんでした（\(gaveUp ? "あきらめます" : "head が変わったら試し直します")）: \(reason)")
            if gaveUp {
                ciFixTracker.giveUp(pullRequest)
            }
            let stop = gaveUp ? "\n\(CIFixTracker.gaveUpMarker)\n\(CIFixTracker.maxAttempts) 回試したので、自動の修正はやめます。" : ""
            await commentOnFailingPullRequest(pullRequest, body: """
                CI の失敗を自動で直せませんでした: \(reason)\(stop)
                失敗したジョブのログを確認し、手元で \(pullRequest.headBranch) を直してください。（askhub-orchestrator）
                """)
        }
    }

    /// 試したことを取り消す。PR の目印も取り消し、再起動の後にも試し直せるようにする
    private func cancelCIFix(of pullRequest: FailingPullRequest, reason: String) async {
        ciFixTracker.cancel(pullRequest)
        await commentOnFailingPullRequest(pullRequest, body: """
            \(CIFixTracker.cancelMarker(pullRequest.headSHA))
            \(reason)。（askhub-orchestrator）
            """)
    }

    /// 上限まで試した後に、また CI が失敗した
    private func giveUpCIFix(of pullRequest: FailingPullRequest) async {
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        log("\(name) の CI が \(pullRequest.headSHA.prefix(7)) でも失敗しましたが、\(CIFixTracker.maxAttempts) 回直させたのであきらめます")
        ciFixTracker.giveUp(pullRequest)
        await commentOnFailingPullRequest(pullRequest, body: """
            \(CIFixTracker.gaveUpMarker)
            \(pullRequest.headSHA.prefix(7)) でも CI が失敗しました。\(CIFixTracker.maxAttempts) 回直させたので、自動の修正はやめます。
            失敗したジョブのログを確認し、手元で \(pullRequest.headBranch) を直してください。（askhub-orchestrator）
            """)
    }

    /// 最終 PR にコメントする。書けたら `true`
    @discardableResult
    private func commentOnFailingPullRequest(_ pullRequest: FailingPullRequest, body: String) async -> Bool {
        do {
            // 人間・ループと同じアカウントで書くので、目印で最終 PR への指示と見分けさせる（docs/protocol.md の「最終 PR への指示」）
            try await github.comment(
                onPullRequest: pullRequest.number,
                in: pullRequest.repository,
                body: "\(FinalPullRequestMarker.orchestrator)\n\(body)"
            )
            return true
        } catch {
            log("\(pullRequest.repository)#\(pullRequest.number) にコメントできませんでした: \(error)")
            return false
        }
    }
}
