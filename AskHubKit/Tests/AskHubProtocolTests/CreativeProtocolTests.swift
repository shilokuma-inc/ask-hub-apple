@testable import AskHubProtocol
import Foundation
import Testing

extension EpicIntentsTests {
    static let creativeTarget = IntentEnvelope.Target(type: "creative")
    static let creativeKinds: [Kind] = [
        Kind(vectors: "payloads/draftCreativeAssets.json", kind: "draftCreativeAssets", target: creativeTarget, targetVersion: "2") {
            try DraftCreativeAssetsIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/approveCreativeAssets.json", kind: "approveCreativeAssets", target: creativeTarget, targetVersion: "2") {
            try ApproveCreativeAssetsIntent(envelope: $0).payload
        }
    ]
}

/// クリエイティブアセットの案（`CreativeSpec`）・`creative.json`・案を頼む / 承認する人の意図
struct CreativeProtocolTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!

    /// app-kit の `tools/tests/creative/spec.json` と同じ案（app-kit の確かめで問題が無いもの）
    static let sample = CreativeSpec(
        colors: .init(background: "#0B1026", background2: "#1B2470", accent: "#5B6CFF", highlight: "#FFD98A", text: "#FFFFFF"),
        screens: .init(header: ["01_home", "02_detail", "03_settings"], search: ["01_home", "02_detail"]),
        locales: [
            .init(
                locale: "ja",
                screenshots: "ja",
                appName: "フィクスチャ",
                header: .init(title: "毎日の記録を*3 秒*で", subtitle: "開いてすぐ書ける、いちばん軽いメモ"),
                search: .init(title: "思いついたら、\nすぐ*メモ*", chips: ["ひと押しで記録", "検索も速い", "広告なし"])
            ),
            .init(
                locale: "en-US",
                screenshots: "en",
                appName: "Fixture",
                header: .init(title: "Capture your day in *3 seconds*", subtitle: "The lightest notes app, ready the moment you open it"),
                search: .init(title: "Think it,\n*note it*", chips: ["One-tap notes", "Instant search", "No ads"])
            )
        ]
    )

    private func envelope(
        kind: String,
        repo: RepositoryFullName? = Self.repo,
        target: IntentEnvelope.Target? = .init(type: "creative"),
        targetVersion: String? = "2",
        payload: [String: JSONValue] = [:]
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: repo,
            target: target,
            targetVersion: targetVersion,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-24T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    private func read(_ name: String) throws -> CreativeFile {
        let file = try #require(try JSONSerialization.jsonObject(with: Vectors.data("state/creative.json")) as? [String: Any])
        let cases = try #require(file["cases"] as? [[String: Any]])
        let value = try #require(cases.first { $0["name"] as? String == name }?["value"], "\(name)")
        return try StateFileCoder.decode(CreativeFile.self, from: JSONSerialization.data(withJSONObject: value))
    }

    // MARK: - 案

    @Test func sampleHasNoProblems() {
        #expect(Self.sample.violations.isEmpty)
        #expect(Self.sample.cautions.isEmpty)
    }

    @Test func refusesMalformedSpecs() {
        func violations(_ change: (inout CreativeSpec) -> Void) -> [String] {
            var spec = Self.sample
            change(&spec)
            return spec.violations
        }
        #expect(!violations { $0.version = 2 }.isEmpty)
        #expect(!violations { $0.colors.text = "white" }.isEmpty)
        #expect(!violations { $0.screens.header = [] }.isEmpty)
        #expect(!violations { $0.screens.search = ["a", "b", "c"] }.isEmpty)
        #expect(!violations { $0.screens.header = ["../etc"] }.isEmpty)
        #expect(!violations { $0.locales = [] }.isEmpty)
        #expect(!violations { $0.locales.append($0.locales[0]) }.isEmpty)
        #expect(!violations { $0.locales[0].locale = "JA" }.isEmpty)
        #expect(!violations { $0.locales[0].screenshots = "../ja" }.isEmpty)
        #expect(!violations { $0.locales[0].header.title = "" }.isEmpty)
        #expect(!violations { $0.locales[0].header.title = String(repeating: "あ", count: 61) }.isEmpty)
        #expect(!violations { $0.locales[0].header.title = "a\tb" }.isEmpty)
        #expect(!violations { $0.locales[0].header.title = "a\nb\nc" }.isEmpty)
        #expect(!violations { $0.locales[0].header.title = "\n" }.isEmpty)
        #expect(!violations { $0.locales[0].search.title = "a\nb\nc\nd" }.isEmpty)
        #expect(!violations { $0.locales[0].appName = "a\nb" }.isEmpty)
        #expect(violations { $0.locales[0].search.title = "a\nb\nc" }.isEmpty)
        #expect(!violations { $0.locales[0].header.title = "*強調" }.isEmpty)
        #expect(!violations { $0.locales[0].search.chips = ["a", "b", "c", "d"] }.isEmpty)
        #expect(!violations { $0.locales[0].search.chips = [String(repeating: "x", count: 31)] }.isEmpty)
        // 一文は空でよい。長さは Unicode のスカラーで数える（app-kit の Python と同じ）
        #expect(violations { $0.locales[0].header.subtitle = "" }.isEmpty)
        #expect(violations { $0.locales[0].header.title = String(repeating: "👍🏽", count: 31) }.isEmpty == false)
    }

    @Test func cautionsMatchAppKit() {
        var spec = Self.sample
        spec.locales[1].search.title = "Free at example.com"
        spec.locales[0].header.subtitle = "© 2026 ¥120"
        spec.locales[0].search.title = "ずっと無料で使える"
        let codes = spec.cautions.map(\.code).sorted()
        #expect(codes == ["forbidden-price", "forbidden-price", "forbidden-price", "forbidden-symbol", "forbidden-url"])
        spec = Self.sample
        spec.colors.text = "#202040"
        #expect(spec.cautions.map(\.code) == ["low-contrast", "low-contrast"])
        #expect(abs(CreativeSpec.contrast("#FFFFFF", "#000000") - 21) < 0.01)
    }

    @Test func encodesInputAsOneSortedLine() throws {
        let json = try Self.sample.inputJSON()
        #expect(!json.contains("\n  "))
        #expect(json.hasPrefix(##"{"colors":{"accent":"#5B6CFF""##))
        let decoded = try JSONDecoder().decode(CreativeSpec.self, from: Data(json.utf8))
        #expect(decoded == Self.sample)
        // 省いた任意の欄は書かない（app-kit は null を受け付けない）
        var spec = Self.sample
        spec.colors.background2 = nil
        spec.locales[1].header.subtitle = nil
        spec.locales[1].search.chips = nil
        let minimal = try spec.inputJSON()
        #expect(!minimal.contains("null") && !minimal.contains("background2"))
    }

    // MARK: - パス

    @Test func previewPaths() {
        let path = StatePath.creativePreview(Self.repo, revision: 3, locale: "en-US", kind: .searchResults)
        #expect(path == "repos/shilokuma-inc/prime-pick-ios/creative/3/en-US/searchResults.b64")
        #expect(StatePath.isCreativePreviewPath(path))
        #expect(StatePath.creative(Self.repo) == "repos/shilokuma-inc/prime-pick-ios/creative.json")
        for bad in [
            "repos/shilokuma-inc/prime-pick-ios/creative/0/ja/searchResults.b64",
            "repos/shilokuma-inc/prime-pick-ios/creative/01/ja/searchResults.b64",
            "repos/shilokuma-inc/prime-pick-ios/creative/1/../searchResults.b64",
            "repos/shilokuma-inc/prime-pick-ios/creative/1/ja/universal.b64",
            "repos/shilokuma-inc/prime-pick-ios/creative/1/ja/searchResults.jpg",
            "repos/shilokuma-inc/prime-pick-ios/store-screenshots/1/ja/searchResults.b64",
            "/repos/shilokuma-inc/prime-pick-ios/creative/1/ja/searchResults.b64"
        ] {
            #expect(!StatePath.isCreativePreviewPath(bad), "\(bad)")
        }
    }

    // MARK: - creative.json

    /// 書き直して読み直すだけでは、読み落とした欄に気づけないので、読んだ値を直接確かめる
    @Test func readsFullFile() throws {
        let file = try read("full")
        let draft = try #require(file.draft)
        #expect(draft.revision == 2 && draft.state == .rendered && draft.awaitsReview)
        #expect(draft.request.comment == "見出しをもっと短く")
        #expect(draft.spec?.locales.map(\.locale) == ["ja", "en-US"])
        #expect(draft.run?.id == 45_000_000_001 && draft.run?.isCompleted == true && draft.screenshotsRun == 44_900_000_000)
        #expect(draft.images.count == 4 && draft.images[1].problems.map(\.code) == ["text-overflow"])
        #expect(draft.problems.map(\.code) == ["low-contrast"])
        #expect(file.previous?.revision == 1)
        #expect(file.approved?.library == .init(total: 4, ready: 3, sentAt: Timestamp(rawValue: "2026-11-23T12:10:00Z")!))
        #expect(file.live?.version?.rawValue == "1.3.0" && file.live?.images.first?.kind == .productPageHeader)
        #expect(file.placed.first?.revision == 1)
        #expect(try read("drafting").draft?.awaitsReview == false)
    }

    @Test func kindsMatchAppStoreConnect() {
        #expect(CreativeKind.productPageHeader.placementType == "PRODUCT_PAGE_HEADER_ASSET")
        #expect(CreativeKind.searchResults.placementType == "APP_STORE_SEARCH_RESULTS_ASSET")
        #expect(CreativeKind.productPageHeader.size == (3840, 1646) && CreativeKind.searchResults.size == (3840, 2560))
        #expect(CreativeKind.allCases.map(\.fileName) == ["product-page-header.png", "search-results.png"])
    }

    // MARK: - 意図

    @Test func readsDraftAndApprove() throws {
        let first = try DraftCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets", targetVersion: "0"))
        #expect(first.repo == Self.repo && first.revision == 0 && first.comment == nil && first.payload.isEmpty)
        #expect(first.target == .init(type: "creative") && first.targetVersion == "0")
        let revise = try DraftCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets", payload: ["comment": .string("短く")]))
        #expect(revise.revision == 2 && revise.comment == "短く")
        let approve = try ApproveCreativeAssetsIntent(envelope: envelope(kind: "approveCreativeAssets"))
        #expect(approve.revision == 2 && approve.targetVersion == "2")
    }

    @Test func refusesMalformedEnvelopes() {
        #expect(throws: MalformedIntent.self) { try DraftCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets", repo: nil)) }
        #expect(throws: MalformedIntent.self) {
            try DraftCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets", target: .init(type: "submission", id: "1.0.0")))
        }
        #expect(throws: MalformedIntent.self) {
            try DraftCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets", target: .init(type: "creative", id: "x")))
        }
        #expect(throws: MalformedIntent.self) {
            try DraftCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets", target: nil))
        }
        for version in [nil, "", "01", "-1", "x"] as [String?] {
            #expect(throws: MalformedIntent.self, "\(String(describing: version))") {
                try DraftCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets", targetVersion: version))
            }
        }
        #expect(throws: MalformedIntent.self) {
            try ApproveCreativeAssetsIntent(envelope: envelope(kind: "approveCreativeAssets", targetVersion: "0"))
        }
        #expect(throws: MalformedIntent.self) { try ApproveCreativeAssetsIntent(envelope: envelope(kind: "draftCreativeAssets")) }
    }
}
