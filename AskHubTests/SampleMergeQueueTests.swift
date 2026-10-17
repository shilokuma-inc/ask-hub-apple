@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// デモモードのマージ待ちのサンプルが、TestFlight へのアップロードの各状態を含むこと（Discussion #449）
struct SampleMergeQueueTests {
    @Test func samplesCoverUploadRunStates() throws {
        let pulls = SampleMergeQueue.pullRequests
        #expect(pulls.map(\.number) == [50, 80, 120, 130, 140, 150])

        // 50: 最新の head を上げ終わっている → 成功・head と同じ・上げ直せる
        let done = try #require(pulls[0].uploadStatus.run)
        #expect(done.isSuccessful)
        #expect(pulls[0].uploadedLatestHead == true)
        #expect(pulls[0].canUpload)

        // 80: 上げている最中 → 実行中・押せない
        let running = try #require(pulls[1].uploadStatus.run)
        #expect(running.isRunning)
        #expect(!pulls[1].canUpload)
        #expect(pulls[1].uploadBlockingReason == "同じ epic ブランチで Upload を実行中です")

        // 120: 前のコミットで失敗 → 失敗・head と違う・上げ直せる
        let failed = try #require(pulls[2].uploadStatus.run)
        #expect(failed.conclusion == .failure)
        #expect(pulls[2].uploadedLatestHead == false)
        #expect(pulls[2].canUpload)

        // 130: まだ上げていない（CodeRabbit は処理中だが CI は成功）→ run は無し・上げられる
        #expect(pulls[3].uploadStatus == .noRuns)
        #expect(pulls[3].uploadedLatestHead == nil)
        #expect(pulls[3].canUpload)

        // サンプルは GitHub に依存しない固定の値
        let runs = pulls.compactMap { $0.uploadStatus.run }
        #expect(runs.count == 3)
        #expect(Set(runs.map(\.startedAt)).count == 1)
        #expect(runs.allSatisfy { $0.url.host() == "github.com" })
    }
}
