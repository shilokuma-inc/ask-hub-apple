import AskHubKit
import Foundation

// epic の最終 PR で CodeRabbit がレビューできないときは、reviewCommand（askhub-review-final）に第三者レビューをさせ、
// 要修正があれば fixCommand（askhub-fix-review）に直させる（Discussion #503）。
// レビュー・修正はメインの checkout に一時 worktree を作るので、コンフリクトの解消と合わせて同じリポジトリでは 1 件ずつにする
extension Orchestrator {
    /// 最終 PR の第三者レビューの対象を取得し、始められるレビュー・修正を裏で始める（終わるのは待たない）
    func startFinalReviews() async {
        guard activeUsageLimit(at: now()) == nil else {
            return
        }
        let candidates: [FinalReviewCandidate]
        do {
            candidates = try await github.finalReviewCandidates(orgs: config.orgs, trust: trust)
        } catch {
            log("第三者レビューの対象の最終 PR を確認できませんでした: \(error)")
            return
        }
        finalReviewCandidates = candidates
        finalReviewTracker.update(with: candidates, now: now())
        startFinalReviews(among: candidates)
        // 始めたもの（レビュー中）も含めて、進み具合を最終 PR に書き出す
        await publishFinalReviewStatuses()
    }

    /// 裏で実行中のレビュー・修正のリポジトリ（名前の小文字）。コンフリクトの解消はこのリポジトリでは始めない
    var finalReviewRepositories: Set<String> {
        Set(finalReviews.keys)
    }

    /// 取得済みの一覧から、始められるレビュー・修正を裏で始める
    func startFinalReviews(among candidates: [FinalReviewCandidate]) {
        guard activeUsageLimit(at: now()) == nil, !drainsConflictResolutions else {
            return
        }
        // 実行中の解消と、終わった後の書き出しを待っているレビュー・修正（`finish` の後も `finalReviews` に残る）のリポジトリは選ばない。
        // 選ぶと、書き出しを待つ間（actor の再入）に同じリポジトリで次を始め、`finalReviews` の Task を上書きして見失う
        let busy = Set(conflictResolutions.keys).union(finalReviews.keys)
        let starts = finalReviewTracker.startable(in: candidates, config: config, now: now(), busyRepositories: busy)
        for start in starts {
            let pullRequest = start.pullRequest
            let key = pullRequest.repository.lowercased()
            finalReviewTracker.start(start.action, for: pullRequest)
            finalReviews[key] = Task {
                // 始めたこと（レビュー中）と結果を書き出してから取り除く（`--once` が書き出しの前に終わらないように）
                await publishFinalReviewStatuses()
                await runFinalReview(start)
                finalReviewTracker.finish(pullRequest)
                await publishFinalReviewStatuses()
                finalReviews[key] = nil
                // 同じリポジトリで待たせていたものを、次のポーリングを待たずに始める。コンフリクトの解消を先にする
                // （待たせ続けないため。解消で head が変わればレビューはやり直しになる）。
                // 今終わった PR は head が変わりうるので、次のポーリングで取得し直してから扱う
                startConflictResolutions(among: conflictingPullRequests)
                startFinalReviews(among: finalReviewCandidates.filter { $0.pullRequest.key != pullRequest.key })
            }
        }
    }

    private func runFinalReview(_ start: FinalReviewTracker.Start) async {
        let pullRequest = start.pullRequest
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        let kind: FinalReviewCommandTemplate.Kind = start.action == .review ? .review : .fix
        let command = kind == .review ? config.reviewCommand : config.fixCommand
        log("\(name)（\(pullRequest.headSHA.prefix(7))）の\(Self.describe(start.action))を始めます")
        let output: String
        do {
            let result = try await runtime.run(
                command.render(for: start.repository, pullRequest: pullRequest),
                input: "",
                // 前回の第三者レビューを信用する author のものだけ読むよう、ループと同じく信用する author も渡す
                environment: loopEnvironment(for: start.repository),
                for: start.repository,
                timeout: kind.timeout
            )
            output = result.output
        } catch {
            await record(start, failure: "\(kind.configKey) を起動できませんでした（\(error)）")
            return
        }
        switch start.action {
        case .review:
            let outcome = FinalReviewTracker.reviewOutcome(in: output)
            // 終わった結果が読めたら、claude の出力に利用上限の文言が混ざっていても結果を使う（投稿済みのレビューを捨てない）
            if case .failed = outcome ?? .failed(reason: ""), recordUsageLimit(in: output) {
                logUsageLimit(start)
                return
            }
            await record(outcome ?? .failed(reason: "コマンドの出力から結果を読み取れませんでした"), for: start)

        case .fix:
            var outcome = FinalReviewTracker.fixOutcome(in: output)
            if case .failed = outcome ?? .failed(reason: ""), recordUsageLimit(in: output) {
                logUsageLimit(start)
                return
            }
            if case let .fixed(head) = outcome, head == pullRequest.headSHA.lowercased() {
                outcome = .failed(reason: "今の head と同じ SHA を直したと返しました")
            }
            await record(outcome ?? .failed(reason: "コマンドの出力から結果を読み取れませんでした"), for: start)
        }
    }

    /// 利用上限で終わったときは、試したことにせず解除を待つ
    private func logUsageLimit(_ start: FinalReviewTracker.Start) {
        let name = "\(start.pullRequest.repository)#\(start.pullRequest.number)"
        log("\(name) の\(Self.describe(start.action))をする claude が利用上限で終わりました。解除の後に試し直します")
    }

    private func record(_ start: FinalReviewTracker.Start, failure reason: String) async {
        switch start.action {
        case .review:
            await record(FinalReviewTracker.ReviewOutcome.failed(reason: reason), for: start)

        case .fix:
            await record(FinalReviewTracker.FixOutcome.failed(reason: reason), for: start)
        }
    }

    private func record(_ outcome: FinalReviewTracker.ReviewOutcome, for start: FinalReviewTracker.Start) async {
        let pullRequest = start.pullRequest
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        let gaveUp = finalReviewTracker.record(outcome, for: pullRequest)
        switch outcome {
        case let .reviewed(must, may):
            // 結果はスクリプトが PR にコメントした
            log("\(name) の第三者レビューが終わりました（要修正 \(must) 件・提案 \(may) 件）")
            if gaveUp {
                await tellGaveUp(pullRequest, reason: "第三者レビューの要修正が \(FinalReviewTracker.maxAttempts) 回続けて収まりませんでした（最新のレビューで要修正 \(must) 件）")
            }

        case .stale:
            log("\(name) の head が進んでいたので、第三者レビューをしませんでした。新しい head でやり直します")

        case let .failed(reason):
            log("\(name) の第三者レビューができませんでした（\(gaveUp ? "あきらめます" : "次のポーリングで試し直します")）: \(reason)")
            if gaveUp {
                await tellGaveUp(pullRequest, reason: "第三者レビューが \(FinalReviewTracker.maxFailures) 回続けて失敗しました: \(reason)")
            }
        }
    }

    private func record(_ outcome: FinalReviewTracker.FixOutcome, for start: FinalReviewTracker.Start) async {
        let pullRequest = start.pullRequest
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        let gaveUp = finalReviewTracker.record(outcome, for: pullRequest)
        switch outcome {
        case let .fixed(head):
            log("\(name) の第三者レビューの要修正を直して push しました（\(pullRequest.headSHA.prefix(7)) → \(head.prefix(7))）。新しい head をレビューします")

        case .stale:
            log("\(name) の head が進んでいたので、要修正を直しませんでした。新しい head でやり直します")

        case let .failed(reason):
            log("\(name) の第三者レビューの要修正を直せませんでした（\(gaveUp ? "あきらめます" : "次のポーリングで試し直します")）: \(reason)")
            if gaveUp {
                await tellGaveUp(pullRequest, reason: "要修正の修正が \(FinalReviewTracker.maxFailures) 回続けて失敗しました: \(reason)")
            }
        }
    }

    /// あきらめたことを PR に知らせる（Q1: アプリからはマージできないまま。人が直して push すればまた回る）
    private func tellGaveUp(_ pullRequest: FinalReviewPullRequest, reason: String) async {
        let name = "\(pullRequest.repository)#\(pullRequest.number)"
        let body = """
            第三者レビューによる自動の修正をやめます（\(pullRequest.headSHA.prefix(7))）: \(reason)
            残った要修正は、この head の第三者レビューのコメントを見てください。手で直して \(pullRequest.headBranch) に push すると、また第三者レビューから回ります。
            アプリからはマージできません（GitHub の画面からはマージできます）。（askhub-orchestrator）
            """
        do {
            try await github.comment(onPullRequest: pullRequest.number, in: pullRequest.repository, body: body)
        } catch {
            log("\(name) にあきらめたことをコメントできませんでした: \(error)")
        }
    }

    private static func describe(_ action: FinalReviewTracker.Action) -> String {
        switch action {
        case .review:
            "第三者レビュー"

        case .fix:
            "第三者レビューの要修正の修正"
        }
    }
}
