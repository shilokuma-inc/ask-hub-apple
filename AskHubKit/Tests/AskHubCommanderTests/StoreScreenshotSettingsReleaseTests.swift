@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 撮り方の設定の無いアプリのリリースで、司令塔が撮り方を作ってから撮る・取り込むときに配置グループを確かめる（#1304）
extension ReleaseWatchTests {
    /// 撮り方の配置グループがリファレンスデータに無ければ、その組は取り込まずにわけを出す（審査に出すときに黙って落ちないように）
    @Test func skipsPlacementGroupsMissingFromTheReferenceData() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]], duo: ["ja": [Self.home], "en": [Self.home]])
        appStore.state.withLock { $0.placementGroups = StoreScreenshotSettingsBuilderTests.groups.filter { $0.id != Self.duo } }
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.sets.allSatisfy { $0.displayType == Self.iPhone })
        #expect(shots.skipped.contains(.init(displayType: Self.duo, reason: WorkflowScreenshotImport.unknownPlacementReason(Self.duo))))
    }
}
