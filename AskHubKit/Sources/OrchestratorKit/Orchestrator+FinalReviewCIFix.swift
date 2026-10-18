import AskHubKit
import Foundation

// epic の最終 PR の CI が失敗していたら、第三者レビューより先に ciFixCommand（askhub-fix-ci）に失敗したジョブのログを読ませて直させる。
// epic が完了した後はループが終わっているので、放っておくと失敗したまま残る。
// 始める・取り消す・あきらめたときは PR に目印（`CIFixMarker`）付きのコメントを書き、それを記録の正本にする（再起動しても同じ head で試し直さない）
extension Orchestrator {
    /// CI の修正を上限まで試した後に、また CI が失敗した PR に、あきらめたことを伝える
    func tellCIFixGiveUps(among candidates: [FinalReviewCandidate]) async {
        for pullRequest in finalReviewTracker.ciFixGiveUps(in: candidates) {
            let name = "\(pullRequest.repository)#\(pullRequest.number)"
            let limit = FinalReviewTracker.maxCIFixAttempts
            log("\(name) の CI が \(pullRequest.headSHA.prefix(7)) でも失敗しましたが、\(limit) 回直させたので自動の修正をやめます")
            finalReviewTracker.giveUpCIFix(pullRequest)
            await commentCIFix(.gaveUp, on: pullRequest, body: """
                \(pullRequest.headSHA.prefix(7)) でも CI が失敗しました。CI の失敗を \(limit) 回直させたので、自動の修正をやめます。
                失敗したジョブのログを確認し、手元で \(pullRequest.headBranch) を直してください。（askhub-orchestrator）
                """)
        }
    }

    /// CI の失敗を直させる。始める前に、試すことを PR に残す（残せなければ始めない）
    func runCIFix(_ start: FinalReviewTracker.Start) async {
        let pullRequest = start.pullRequest
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        let attempt = (finalReviewCandidate(for: pullRequest)?.ciFix.attemptedSHAs.count ?? 0) + 1
        let posted = await commentCIFix(.attempt, on: pullRequest, body: """
            \(pullRequest.headSHA.prefix(7)) で CI が失敗しているので、失敗したジョブのログを読ませて直させます\
            （\(attempt) / \(FinalReviewTracker.maxCIFixAttempts) 回目）。（askhub-orchestrator）
            """)
        // 試したことを PR に残せなければ、再起動の後に同じ head で二重に直させかねないので始めない（次のポーリングで試し直す）
        guard posted else {
            finalReviewTracker.cancelCIFix(pullRequest)
            return
        }
        log("\(name)（\(pullRequest.headSHA.prefix(7))）の CI の失敗の修正を始めます")
        let output: String
        do {
            let result = try await runtime.run(
                config.ciFixCommand.render(for: start.repository, pullRequest: pullRequest),
                input: "",
                environment: loopEnvironment(for: start.repository),
                for: start.repository,
                timeout: FinalReviewCommandTemplate.Kind.fixCI.timeout
            )
            output = result.output
        } catch {
            await recordCIFix(.failed(reason: "ciFixCommand を起動できませんでした（\(error)）"), for: start)
            return
        }
        var outcome = FinalReviewTracker.fixOutcome(in: output)
        // 利用上限で終わったなら、試したことにせず解除を待つ
        if case .failed = outcome ?? .failed(reason: ""), recordUsageLimit(in: output) {
            log("\(name) の CI の失敗を直す claude が利用上限で終わりました。解除の後に試し直します")
            await cancelCIFix(of: pullRequest, reason: "Claude の利用上限で止まったので、解除の後に試し直します")
            return
        }
        if case let .fixed(head) = outcome, head == pullRequest.headSHA.lowercased() {
            outcome = .failed(reason: "今の head と同じ SHA を直したと返しました")
        }
        await recordCIFix(outcome ?? .failed(reason: "コマンドの出力から結果を読み取れませんでした"), for: start)
    }

    func recordCIFix(_ outcome: FinalReviewTracker.FixOutcome, for start: FinalReviewTracker.Start) async {
        let pullRequest = start.pullRequest
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        finalReviewTracker.recordCIFix(outcome, for: pullRequest)
        switch outcome {
        case let .fixed(head):
            log("\(name) の CI の失敗を直して push しました（\(pullRequest.headSHA.prefix(7)) → \(head.prefix(7))）")
            await commentCIFix(nil, on: pullRequest, body: """
                CI の失敗を直し、\(pullRequest.headBranch) に push しました（\(pullRequest.headSHA.prefix(7)) → \(head.prefix(7))）。
                直した内容を確認し、CI が通ってからマージしてください。（askhub-orchestrator）
                """)

        case .stale:
            log("\(name) の head が進んでいたので、CI の失敗を直しませんでした。新しい head の CI を待ちます")
            await cancelCIFix(of: pullRequest, reason: "直させる前に \(pullRequest.headBranch) が更新されていたので、この試行は数えません")

        case let .failed(reason):
            let gaveUp = finalReviewCandidate(for: pullRequest).map(finalReviewTracker.reachedCIFixLimit) ?? false
            log("\(name) の CI の失敗を直せませんでした（\(gaveUp ? "自動の修正をやめます" : "head が変わったら試し直します")）: \(reason)")
            if gaveUp {
                finalReviewTracker.giveUpCIFix(pullRequest)
            }
            let stop = gaveUp ? "\nCI の失敗を \(FinalReviewTracker.maxCIFixAttempts) 回直させたので、自動の修正をやめます。" : ""
            await commentCIFix(gaveUp ? .gaveUp : nil, on: pullRequest, body: """
                CI の失敗を自動で直せませんでした: \(reason)\(stop)
                失敗したジョブのログを確認し、手元で \(pullRequest.headBranch) を直してください。（askhub-orchestrator）
                """)
        }
    }

    /// 試したことを取り消す。PR の目印も取り消し、再起動の後にも試し直せるようにする
    private func cancelCIFix(of pullRequest: FinalReviewPullRequest, reason: String) async {
        finalReviewTracker.cancelCIFix(pullRequest)
        await commentCIFix(.cancel, on: pullRequest, body: "\(reason)。（askhub-orchestrator）")
    }

    /// 最後に取得した、その PR の状態
    private func finalReviewCandidate(for pullRequest: FinalReviewPullRequest) -> FinalReviewCandidate? {
        finalReviewCandidates.first { $0.pullRequest.key == pullRequest.key }
    }

    /// 最終 PR に、CI の修正の目印（`action` が `nil` なら目印なし）を付けてコメントする。書けたら `true`
    @discardableResult
    private func commentCIFix(_ action: CIFixMarker.Action?, on pullRequest: FinalReviewPullRequest, body: String) async -> Bool {
        // 人間・ループと同じアカウントで書くので、目印で最終 PR への指示と見分けさせる（docs/protocol.md の「最終 PR への指示」）
        let marker = action.flatMap { CIFixMarker(action: $0, sha: pullRequest.headSHA).htmlComment }
        let text = ([FinalPullRequestMarker.orchestrator] + (marker.map { [$0] } ?? []) + [body]).joined(separator: "\n")
        do {
            try await github.comment(onPullRequest: pullRequest.number, in: pullRequest.repository, body: text)
            return true
        } catch {
            log("\(pullRequest.repository)#\(pullRequest.number) に CI の修正についてコメントできませんでした: \(error)")
            return false
        }
    }
}
