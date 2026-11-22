@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// クリエイティブアセット（`creative.json`）の案の表示と、案を頼む・承認するの意図
extension StateClientServiceTests {
    static let creativeKey = #"{"keyId":"\#(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000001"}"#
    static let creativeSpec = """
        {"v":1,"layout":"standard","colors":{"background":"#0B1026","accent":"#5B6CFF","text":"#FFFFFF"},
         "screens":{"header":["01_home"],"search":["01_home"]},
         "locales":[{"locale":"ja","screenshots":"ja","appName":"習慣ログ","header":{"title":"習慣を*ひと押し*で"},"search":{"title":"続く記録"}}]}
        """

    static func creativeImages(_ revision: Int) -> String {
        let images = ["productPageHeader", "searchResults"].map { kind in
            let problems = kind == "productPageHeader" ? #"[{"code":"text-overflow","message":"見出しがはみ出す"}]"# : "[]"
            return #"{"locale":"ja","kind":"\#(kind)","md5":"\#(String(repeating: "a", count: 32))","#
                + #""preview":"repos/\#(repo)/creative/\#(revision)/ja/\#(kind).b64","problems":\#(problems)}"#
        }
        return "[" + images.joined(separator: ",") + "]"
    }

    static func creativeFiles(state: String = "rendered", approved: String = "null", placed: String = "[]") -> [String: String] {
        askingEpic(extra: [
            StatePath.creative(RepositoryFullName(rawValue: repo)!): """
            {"v":1,"repo":"\(repo)",
             "draft":{"revision":2,"request":{"approval":\(creativeKey),"comment":"短く","at":"2027-01-15T06:00:00Z"},
                      "state":"\(state)","spec":\(creativeSpec),"reason":"続けやすさを見出しにしました","draftedAt":"2027-01-15T06:05:00Z",
                      "images":\(state == "rendered" ? creativeImages(2) : "[]"),"problems":[]},
             "previous":{"revision":1,"spec":\(creativeSpec),"images":\(creativeImages(1))},
             "approved":\(approved),"placed":\(placed),"updatedAt":"2027-01-15T06:30:00Z"}
            """
        ])
    }

    @Test
    func buildsCreativeAndAwaitsReview() async throws {
        let fixture = try makeService(files: Self.creativeFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        let creative = try #require(snapshot.creative(of: Self.repo))
        #expect(creative.awaitsReview && !creative.isWorking)
        #expect(creative.draft?.revision == 2 && creative.draft?.comment == "短く" && creative.draft?.titles["ja"] == "習慣をひと押しで")
        #expect(creative.locales == ["ja"] && creative.previous?.revision == 1)
        #expect(creative.draft?.images.first { $0.kind == .productPageHeader }?.problems.map(\.code) == ["text-overflow"])
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.kind == .creative })
        #expect(item.title == "ヘッダーと検索結果の案を確かめる" && item.urgency == .whenFree && item.route == .creative(Self.repo))
        // 見た案の版のときだけ送れる
        #expect(fixture.service.supports(.approveCreativeAssets(repositoryID: Self.repo, revision: 2)))
        #expect(!fixture.service.supports(.approveCreativeAssets(repositoryID: Self.repo, revision: 1)))
        #expect(fixture.service.supports(.draftCreativeAssets(repositoryID: Self.repo, revision: 2, comment: "もっと短く")))
        #expect(!fixture.service.supports(.draftCreativeAssets(repositoryID: Self.repo, revision: 1, comment: nil)))
        #expect(!fixture.service.supports(.draftCreativeAssets(repositoryID: Self.repo, revision: 2, comment: "")))
    }

    /// 作っている途中は頼み直せず、承認もできない。承認した案は確かめる番に出さない
    @Test
    func workingAndApprovedCreativesAreNotActionable() async throws {
        let working = try makeService(files: Self.creativeFiles(state: "rendering"))
        let snapshot = try await working.service.fetchSnapshot()
        #expect(snapshot.creative(of: Self.repo)?.isWorking == true)
        #expect(!working.service.supports(.draftCreativeAssets(repositoryID: Self.repo, revision: 2, comment: nil)))
        #expect(!working.service.supports(.approveCreativeAssets(repositoryID: Self.repo, revision: 2)))
        let approvedJSON = """
            {"revision":2,"spec":\(Self.creativeSpec),"images":\(Self.creativeImages(2)),"approval":\(Self.creativeKey),
             "at":"2027-01-15T07:00:00Z","library":{"total":2,"ready":1,"sentAt":"2027-01-15T07:05:00Z"}}
            """
        let approved = try makeService(files: Self.creativeFiles(approved: approvedJSON))
        let approvedSnapshot = try await approved.service.fetchSnapshot()
        let creative = try #require(approvedSnapshot.creative(of: Self.repo))
        #expect(!creative.awaitsReview && creative.approved?.libraryReady == 1 && creative.approved?.libraryTotal == 2)
        #expect(creative.approved?.isPlaceable == false && creative.approved?.placedIn == nil)
        #expect(InboxBuilder.items(from: approvedSnapshot, now: now).allSatisfy { $0.kind != .creative })
        // 載せた版は、承認した案の版の記録のうち新しいもの（新しい順に並ぶ）
        let placed = """
            [{"version":"1.3.0","revision":2,"at":"2027-01-20T00:00:00Z"},{"version":"1.2.0","revision":1,"at":"2027-01-10T00:00:00Z"}]
            """
        let placedFixture = try makeService(files: Self.creativeFiles(approved: approvedJSON, placed: placed))
        let placedSnapshot = try await placedFixture.service.fetchSnapshot()
        #expect(placedSnapshot.creative(of: Self.repo)?.approved?.placedIn == "1.3.0")
        #expect(placedSnapshot.creative(of: Self.repo)?.status == "案 2 を 1.3.0 に載せました")
    }

    /// 頼むと承認は、封筒の repo と人が見た案の版に結びつけて送り、送った結果を先に出す
    @Test
    func creativeIntentsAreSentAndOverlaid() async throws {
        let fixture = try makeService(files: Self.creativeFiles())
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.approveCreativeAssets(repositoryID: Self.repo, revision: 2))
        let approve = try ApproveCreativeAssetsIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        #expect(approve.repo.rawValue == Self.repo && approve.revision == 2)
        let overlaid = try #require(fixture.service.snapshot(overlaying: [])?.creative(of: Self.repo))
        #expect(overlaid.approved?.revision == 2 && !overlaid.awaitsReview)
        #expect(HumanIntent.approveCreativeAssets(repositoryID: Self.repo, revision: 2).targets == [.creative(Self.repo)])
    }

    /// まだ案の無いリポジトリに頼むと、最初の案を書いている途中として出す
    @Test
    func firstCreativeRequestIsOverlaid() async throws {
        let fixture = try makeService(files: Self.askingEpic(extra: [:]))
        _ = try await fixture.service.fetchSnapshot()
        #expect(fixture.service.supports(.draftCreativeAssets(repositoryID: Self.repo, revision: 0, comment: nil)))
        try await fixture.service.perform(.draftCreativeAssets(repositoryID: Self.repo, revision: 0, comment: nil))
        let draft = try DraftCreativeAssetsIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        #expect(draft.revision == 0 && draft.comment == nil)
        let creative = try #require(fixture.service.snapshot(overlaying: [])?.creative(of: Self.repo))
        #expect(creative.draft?.revision == 1 && creative.draft?.state == .drafting && creative.isWorking)
    }

    @Test
    func creativePreviewsAreDecodedFromBase64() async throws {
        var files = Self.creativeFiles()
        let path = "repos/\(Self.repo)/creative/2/ja/productPageHeader.b64"
        files[path] = Data("JPEG の見本".utf8).base64EncodedString()
        let fixture = try makeService(files: files)
        #expect(try await fixture.service.screenshot(at: path) == Data("JPEG の見本".utf8))
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.screenshot(at: "repos/\(Self.repo)/creative/2/ja/universal.b64")
        }
    }
}
