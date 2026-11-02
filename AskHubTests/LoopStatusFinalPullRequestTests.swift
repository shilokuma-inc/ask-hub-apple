@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// ステータスタブで、完了のループを最終 PR の段階に応じて出し分ける（Discussion #808）
@MainActor
struct LoopStatusFinalPullRequestTests {
    @Test func showsCompletedSampleLoopsByFinalPullRequestStage() async {
        // 完了のループを、マージ待ちのサンプルの最終 PR の段階で出し分ける（Discussion #808）
        let model = LoopStatusModel.sample()
        await model.refresh()
        let now = Date()
        let pulls = SampleMergeQueue.pullRequests
        func row(_ name: String) -> LoopStatusRow? {
            model.rows.first { $0.repository.hasSuffix("/\(name)") }
        }
        func texts(_ name: String) -> [String] {
            guard let row = row(name) else {
                return []
            }
            return model.loopItems(of: row).map { item in
                item.display(now: now).applying(item.row.completionStatus(now: now, pullRequests: pulls)).statusText
            }
        }
        #expect(texts("pair-quiz-ios") == ["実行中", "回答待ち", "最終 PR の CI 失敗"])
        #expect(texts("focus-timer-ios") == ["最終 PR の CI 待ち", "実行中"])
        // lingo-cards の完了のループには最終 PR が無い
        let lingo = row("lingo-cards")
        #expect(lingo?.completionStatus(now: now, pullRequests: pulls) == .finalPullRequestNotFound)
        // マージ待ちを取れていなければ今までどおり「完了」
        #expect(lingo?.completionStatus(now: now, pullRequests: nil)?.statusText == "完了（最終 PR のマージ待ち）")
        // 最終 PR が CI 失敗の pair-quiz-ios の手動ループを、異常に 1 つ足す
        #expect(model.abnormalCount(now: now) == 3)
        #expect(model.abnormalCount(now: now, finalPullRequests: pulls) == 4)
        #expect(model.abnormalCount(now: now, finalPullRequests: nil) == 3)
    }
}
