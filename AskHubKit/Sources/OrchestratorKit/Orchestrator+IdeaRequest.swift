import AskHubKit
import Foundation

/// 新機能の依頼（`idea-request`）の処理: claude に質問付きの Discussion を作らせる
extension Orchestrator {
    func handleIdeaRequests() async throws {
        let issues = try await github.ideaRequests(orgs: config.orgs)
        ideaTracker.prune(keeping: issues)

        // 依頼 Issue への後処理（リンクのコメント・クローズ・失敗の通知）。失敗したら次のポーリングで続きから
        for (issue, followUp) in ideaTracker.followUps(in: issues) {
            await perform(followUp, on: issue)
        }

        guard let (issue, repository) = ideaTracker.next(in: issues, config: config, trust: trust) else {
            return
        }
        let name = "\(issue.repository)#\(issue.number)"
        log("\(name) の依頼から、質問付きの Discussion を作らせます")
        let prompt = IdeaPrompt.make(for: issue, trustedAuthors: trust.authors(for: issue.repository).sortedLogins)
        let arguments = config.ideaCommand.render(for: repository)
        let reason: String
        do {
            // プロンプト（依頼の本文を含む）は引数ではなく標準入力で渡す
            let result = try await runtime.run(arguments, input: prompt, for: repository, timeout: Self.ideaCommandTimeout)
            if result.status == 0, let url = IdeaPrompt.discussionURL(in: result.output, repository: issue.repository) {
                ideaTracker.recordCreated(url, for: issue)
                log("\(name) の依頼から Discussion を作りました: \(url.absoluteString)")
                await perform(.commentAndClose(url), on: issue)
                return
            }
            // 利用上限で失敗したなら、失敗に数えず解除を待つ
            if recordUsageLimit(in: result.output) {
                log("\(name) の Discussion を作る claude が利用上限で終わりました。解除の後に作り直します")
                return
            }
            reason = "Discussion の URL を受け取れませんでした（終了コード \(result.status)）"
        } catch {
            reason = "ideaCommand を起動できませんでした（\(error)）"
        }
        if ideaTracker.recordFailure(for: issue, reason: reason) {
            log("\(name) の Discussion を \(IdeaRequestTracker.maxAttempts) 回作れなかったので、やめます: \(reason)")
            await perform(.reportFailure(reason: reason), on: issue)
        } else {
            log("\(name) の Discussion を作れませんでした。次のポーリングで再試行します: \(reason)")
        }
    }

    /// 依頼 Issue への後処理を 1 段ずつ進める。コメントを重ねないよう、済んだ段は記録してから次へ進む
    private func perform(_ followUp: IdeaRequestTracker.FollowUp, on issue: IdeaRequestIssue) async {
        let name = "\(issue.repository)#\(issue.number)"
        do {
            switch followUp {
            case let .commentAndClose(url):
                try await github.comment(on: issue, body: """
                    質問付きの Discussion を作りました: \(url.absoluteString)

                    AskHub アプリの「要回答」から回答し、「回答を確定してループを始める」を押してください。（askhub-orchestrator）
                    """)
                ideaTracker.recordCommented(issue)
                try await github.close(issue)
                ideaTracker.recordCompleted(issue)
                log("\(name) に Discussion へのリンクをコメントしてクローズしました")

            case .close:
                try await github.close(issue)
                ideaTracker.recordCompleted(issue)
                log("\(name) をクローズしました")

            case let .reportFailure(reason):
                // 人が気づけるよう、依頼 Issue に書き残す（Issue は開いたまま）
                try await github.comment(on: issue, body: """
                    質問付きの Discussion を作れませんでした（\(IdeaRequestTracker.maxAttempts) 回試行）: \(reason)
                    担当 PC のオーケストレーターのログと ideaCommand の設定を確認してください。（askhub-orchestrator）
                    """)
                ideaTracker.recordFailureReported(issue)
            }
        } catch {
            log("\(name) の後処理に失敗しました（次のポーリングで続きから再試行します）: \(error)")
        }
    }
}
