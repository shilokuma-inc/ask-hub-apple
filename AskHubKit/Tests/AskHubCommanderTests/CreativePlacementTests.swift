@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 人が承認したクリエイティブアセットを、審査に出すときに編集できる iOS の版の言語に置く（`AppStoreSubmission+Creative`）
extension ReleaseWatchTests {
    static let headerMD5 = String(repeating: "1", count: 32)
    static let searchMD5 = String(repeating: "2", count: 32)

    func approvedCreative(revision: Int = 2, ready: Int = 2) -> CreativeFile {
        let spec = CreativeProtocolFixtures.spec
        let images = [(CreativeKind.productPageHeader, Self.headerMD5), (.searchResults, Self.searchMD5)].map { kind, md5 in
            let preview = StatePath.creativePreview(Self.repo, revision: revision, locale: "ja", kind: kind)
            return CreativeFile.Image(locale: "ja", kind: kind, md5: md5, preview: preview)
        }
        let approval = IntentReference(keyId: SubmissionHandlersTests.keyID, nonce: ULID(rawValue: "01JCN0NCE00000000000000077")!)
        return CreativeFile(
            repo: Self.repo,
            approved: .init(
                revision: revision,
                spec: spec,
                images: images,
                approval: approval,
                at: Timestamp(Self.now),
                library: .init(total: 2, ready: ready, sentAt: Timestamp(Self.now))
            ),
            updatedAt: Timestamp(Self.now)
        )
    }

    @Test func placesApprovedCreativeAtSubmit() async throws {
        var file = try await readyToSubmit()
        file.submit?.creative = .init(revision: 2)
        try await putSubmission(file)
        await store.put(StatePath.creative(Self.repo), data: try StateFileCoder.encode(approvedCreative()))
        appStore.state.withLock { state in
            state.libraryImages[AppStoreScreenshot.referenceName(checksum: Self.headerMD5)] = [
                AppStoreLibraryImage(id: "img-header", state: "PREPARE_FOR_SUBMISSION", specId: "HEADER_SPEC")
            ]
            state.libraryImages[AppStoreScreenshot.referenceName(checksum: Self.searchMD5)] = [
                AppStoreLibraryImage(id: "img-search", state: "PREPARE_FOR_SUBMISSION", specId: "SEARCH_SPEC")
            ]
            // 前の版から写った古いヘッダー（同じ配置グループ）は消してから置く
            state.creativePlacements["l-ja"] = [
                "PRODUCT_PAGE_HEADER_ASSET": [AppStoreCreativePlacement(id: "placement-old", imageID: "img-old", group: "HEADER_GROUP")]
            ]
        }
        await watch().refresh()
        let writes = appStore.state.withLock { $0.writes }
        let submitAt = try #require(writes.firstIndex(of: "createReviewSubmission iOS"))
        #expect(Array(writes[..<submitAt].suffix(3)) == [
            "deletePlacement placement-old",
            "placeCreative img-header l-ja PRODUCT_PAGE_HEADER_ASSET",
            "placeCreative img-search l-ja APP_STORE_SEARCH_RESULTS_ASSET"
        ])
        let data = try #require(await store.data(at: StatePath.creative(Self.repo)))
        let creative = try StateFileCoder.decode(CreativeFile.self, from: data)
        #expect(creative.placed.map(\.revision) == [2] && creative.placed.first?.version.rawValue == "1.2.0")
    }

    /// 受け付けた後に承認した案が変わっていたら、黙って載せずに出さず、人に知らせる
    @Test func stopsWhenApprovedCreativeChanged() async throws {
        var file = try await readyToSubmit()
        file.submit?.creative = .init(revision: 2)
        try await putSubmission(file)
        await store.put(StatePath.creative(Self.repo), data: try StateFileCoder.encode(approvedCreative(revision: 3)))
        await watch().refresh()
        let saved = try await submission()
        #expect(saved.problem?.step == .submit && saved.problem?.needsHuman == true)
        #expect(appStore.state.withLock { $0.writes }.allSatisfy { !$0.hasPrefix("submitReviewSubmission") })
    }

    /// 載せない（`creative` を送らない）なら、承認した案があっても置かない
    @Test func leavesCreativeWhenNotChosen() async throws {
        _ = try await readyToSubmit()
        await store.put(StatePath.creative(Self.repo), data: try StateFileCoder.encode(approvedCreative()))
        await watch().refresh()
        #expect(appStore.state.withLock { $0.writes }.allSatisfy { !$0.hasPrefix("placeCreative") })
    }

    @Test func refusesCreativeThatIsNotReady() {
        let choice = SubmissionFile.CreativeChoice(revision: 2)
        #expect(SubmitForReviewHandler.problem(creative: choice, on: approvedCreative()) == nil)
        #expect(SubmitForReviewHandler.problem(creative: choice, on: approvedCreative(revision: 3)) != nil)
        #expect(SubmitForReviewHandler.problem(creative: choice, on: approvedCreative(ready: 1))?.contains("ライブラリ") == true)
        #expect(SubmitForReviewHandler.problem(creative: choice, on: nil) != nil)
    }
}
