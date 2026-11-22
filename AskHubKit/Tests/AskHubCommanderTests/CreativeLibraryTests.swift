@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 承認したクリエイティブアセットを App Store Connect のライブラリに上げる（`CreativeWatch+Library`）
extension ReleaseWatchTests {
    /// 書き出して取り込むまで進める
    func renderAndImport(_ watch: CreativeWatch) async throws {
        try await draftAndDispatch(watch)
        creativeArtifacts(report: Self.cleanReport, files: Self.allImages)
        hosting.workflows.withLock { $0.runs[Self.creativeRun] = creativeRunDetail(status: "completed", conclusion: "success") }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
    }

    @Test func uploadsTheApprovedCreativeToTheLibrary() async throws {
        try await prepareCreative()
        let originals = temporaryOriginals()
        defer { try? FileManager.default.removeItem(at: originals) }
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: originals)
        try await renderAndImport(watch)
        // 上げた直後は Apple が処理している
        appStore.state.withLock { $0.sentState = "UPLOAD_COMPLETE" }
        let approve = creativeEnvelope("approveCreativeAssets", revision: 1, nonce: 5)
        #expect(try await ApproveCreativeAssetsHandler().handle(approve, in: creativeContext) == .accept)
        await watch.refresh()
        var approved = try #require(try await creativeFile().approved)
        // 言語が違っても同じ画像は 1 回だけ上げる（見本の画像はどの言語も同じ）
        #expect(approved.library?.total == 2 && approved.library?.ready == 0)
        #expect(appStore.state.withLock { $0.writes.filter { $0.hasPrefix("sendCreativeImage") }.count } == 2)

        // 5 分たってから読み直し、処理が済んだら数える。処理中の画像は消さず、上げ直さない
        let references = Set(approved.images.map { AppStoreScreenshot.referenceName(checksum: $0.md5) })
        for reference in references { appStore.setLibraryState(reference, "PREPARE_FOR_SUBMISSION") }
        await watch.refresh()
        #expect(try await creativeFile().approved?.library?.ready == 0)
        clock.advance(minutes: 5)
        await watch.refresh()
        approved = try #require(try await creativeFile().approved)
        #expect(approved.library?.ready == 2 && !CreativeWatch.awaitsLibrary(approved))
        let writes = appStore.state.withLock { $0.writes }
        #expect(writes.filter { $0.hasPrefix("sendCreativeImage") || $0.hasPrefix("deleteImage") }.count == 2)
    }

    @Test func recordsImagesTheLibraryRefused() async throws {
        try await prepareCreative()
        let originals = temporaryOriginals()
        defer { try? FileManager.default.removeItem(at: originals) }
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: originals)
        try await renderAndImport(watch)
        appStore.state.withLock { $0.sentState = "UPLOAD_COMPLETE" }
        let approve = creativeEnvelope("approveCreativeAssets", revision: 1, nonce: 6)
        _ = try await ApproveCreativeAssetsHandler().handle(approve, in: creativeContext)
        await watch.refresh()
        let approved = try #require(try await creativeFile().approved)
        let header = try #require(approved.images.first { $0.kind == .productPageHeader })
        appStore.setLibraryState(AppStoreScreenshot.referenceName(checksum: header.md5), "FAILED", details: "IMAGE_TOO_LARGE")
        appStore.setLibraryState(
            AppStoreScreenshot.referenceName(checksum: try #require(approved.images.first { $0.kind == .searchResults }).md5),
            "PREPARE_FOR_SUBMISSION"
        )
        clock.advance(minutes: 5)
        await watch.refresh()
        let after = try #require(try await creativeFile().approved)
        #expect(after.library?.ready == 1 && !CreativeWatch.awaitsLibrary(after))
        // 受け付けなかった画像を使う言語のすべてに、わけを書く（書き出しの問題は残す）
        let refused = after.images.filter { $0.kind == .productPageHeader }.flatMap(\.problems).map(\.code)
        #expect(refused.filter { $0 == "library-failed" }.count == 2 && refused.contains("outside-safe-area"))
    }
}
