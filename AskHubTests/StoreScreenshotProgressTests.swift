@testable import AskHub
import AskHubProtocol
import Foundation
import Testing

/// 撮っている間の今の段階（リリースの画面の「スクショ」の段取り）
struct StoreScreenshotProgressTests {
    @Test func describesTheCurrentStage() {
        let now = Timestamp(Date(timeIntervalSince1970: 1_795_000_000))
        var shots = SubmissionFile.StoreScreenshots(state: .capturing, startedAt: now)
        // UI テストの撮り方は、今までどおりの文言（nil）
        #expect(StateSnapshotBuilder.progress(of: shots) == nil)
        shots.run = .init(dispatchedAt: now)
        #expect(StateSnapshotBuilder.progress(of: shots) == "GitHub Actions の撮影を待っています")
        shots.run?.status = "in_progress"
        #expect(StateSnapshotBuilder.progress(of: shots) == "GitHub Actions で撮っています")
        shots.run?.status = "completed"
        #expect(StateSnapshotBuilder.progress(of: shots) == "撮った画像を取り込んで、前回の App Store のものと比べています")
        shots.library = .init(total: 5, ready: 2, sentAt: now)
        #expect(StateSnapshotBuilder.progress(of: shots) == "App Store Connect の取り込みを待っています（2 / 5 枚）")
        shots.state = .captured
        #expect(StateSnapshotBuilder.progress(of: shots) == nil)
    }
}
