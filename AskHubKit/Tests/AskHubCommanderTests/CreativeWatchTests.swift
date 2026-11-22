@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import CoreGraphics
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers

/// 決めた案を返し、受け取った材料を残す
final class FakeCreativeDrafter: CreativeDrafting {
    let requests = OSAllocatedUnfairLock<[CreativeDraftRequest]>(initialState: [])
    /// 決めると、案を書けずにこれを投げる
    let failure = OSAllocatedUnfairLock<ReleaseNotesFailure?>(initialState: nil)

    func draft(_ request: CreativeDraftRequest) async throws(ReleaseNotesFailure) -> CreativeProposal {
        requests.withLock { $0.append(request) }
        if let failure = failure.withLock({ $0 }) { throw failure }
        let locales = request.locales.map { locale in
            CreativeSpec.Localization(
                locale: locale.locale,
                screenshots: locale.locale == "ja" ? "ja" : "en",
                appName: locale.appName,
                header: .init(title: "推しの記念日を*忘れない*"),
                search: .init(title: "推し活の予定を\nひと目で", chips: ["カウントダウン", "ウィジェット"])
            )
        }
        let spec = CreativeSpec(
            colors: .init(background: "#1B1036", accent: "#FF6FAE", text: "#FFFFFF"),
            screens: .init(header: ["01_home", "02_detail"], search: ["01_home"]),
            locales: locales
        )
        return CreativeProposal(spec: spec, reason: "記念日を忘れないことを見出しにしました")
    }
}

/// 書き出しの artifact の代わり（zip は「パス → 中身」の JSON）
struct FakeCreativeExtractor: StoreScreenshotArtifactExtracting {
    static func zip(_ files: [String: Data]) -> Data {
        (try? JSONEncoder().encode(files)) ?? Data()
    }

    func extract(_ zip: Data, into directory: URL) async throws -> [String: [URL]] {
        let files = try JSONDecoder().decode([String: Data].self, from: zip)
        var folders: [String: [URL]] = [:]
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let file = directory.appendingPathComponent("files/\(path)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            folders[String(path.split(separator: "/")[0]), default: []].append(file)
        }
        return folders
    }

    func extractFile(_ zip: Data, named name: String, maximumBytes: Int, into directory: URL) async throws -> Data {
        let files = try JSONDecoder().decode([String: Data].self, from: zip)
        guard files.count == 1, let data = files[name], data.count <= maximumBytes else { throw ArtifactProblem("\(name) だけでない") }
        return data
    }
}

/// アルファの無い RGB の PNG（書き出しの寸法）
func creativePNG(_ kind: CreativeKind, alpha: Bool = false) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let (width, height) = kind.size
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
    context.setFillColor(CGColor(red: 0.1, green: 0.06, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// クリエイティブアセットの案: 頼む・承認するの受け付けと、Claude の案 → 書き出しの起動・見張り → 取り込み
extension ReleaseWatchTests {
    static let creativeRun = 45_100_000_201
    static let header = creativePNG(.productPageHeader)
    static let search = creativePNG(.searchResults)

    func creativeWatch(drafter: FakeCreativeDrafter, originals: URL) -> CreativeWatch {
        CreativeWatch(
            context: creativeContext,
            stores: [appStore],
            sources: sources,
            hosting: hosting,
            artifacts: FakeCreativeExtractor(),
            drafter: drafter,
            originals: originals,
            log: { _ in }
        )
    }

    var creativeContext: CommanderContext {
        let clock = clock
        return CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { clock.now }
    }

    /// App Store Connect のアプリ（配信中の iOS の版に ja・en-US）と、既定のブランチ
    func prepareCreative() async throws {
        try await addRepository()
        live()
        appStore.state.withLock { state in
            state.localizations["live-0"] = [
                AppStoreLocalization(
                    id: "6740000101", locale: "ja", whatsNew: nil, listing: ListingText(locale: "ja", description: "推しの記念日を数える")
                ),
                AppStoreLocalization(
                    id: "6740000102", locale: "en-US", whatsNew: nil, listing: ListingText(locale: "en-US", description: "Count days")
                )
            ]
            state.appNames = ["ja": "推し活カウントダウン", "en-US": "Oshi Countdown"]
        }
        hosting.state.withLock { $0.branches["develop"] = Self.developHead }
    }

    func creativeEnvelope(_ kind: String, revision: Int, payload: [String: JSONValue] = [:], nonce: Int = 1) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: Self.repo,
            target: .init(type: "creative"),
            targetVersion: String(revision),
            payload: payload,
            issuedAt: Timestamp(Self.now),
            nonce: ULID(rawValue: String(format: "01JCN0NCE0000000000000%04d", nonce))!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    func creativeFile() async throws -> CreativeFile {
        let data = try #require(await store.data(at: StatePath.creative(Self.repo)))
        return try StateFileCoder.decode(CreativeFile.self, from: data)
    }

    func creativeRunDetail(status: String = "in_progress", conclusion: String? = nil) -> WorkflowRunDetail {
        WorkflowRunDetail(
            id: Self.creativeRun,
            status: status,
            conclusion: conclusion,
            event: "workflow_dispatch",
            path: ".github/workflows/app-store-creative.yml",
            headBranch: "develop",
            headSHA: Self.developHead,
            createdAt: Self.now,
            url: URL(string: "https://github.com/\(Self.repo)/actions/runs/\(Self.creativeRun)")
        )
    }

    /// 書き出しの artifact（`report` の画像ごとの問題と、`failure`）
    func creativeArtifacts(report: String, files: [String: Data]? = nil) {
        hosting.workflows.withLock { state in
            var artifacts = [RunArtifact(id: 11, name: "creative-report", size: 2_000, expired: false)]
            state.zips[11] = FakeCreativeExtractor.zip(["report.json": Data(report.utf8)])
            if let files {
                artifacts.append(RunArtifact(id: 12, name: "creative-assets", size: 20_000_000, expired: false))
                state.zips[12] = FakeCreativeExtractor.zip(files)
            }
            state.artifacts[Self.creativeRun] = artifacts
        }
    }

    static let cleanReport = #"""
        {"v": 1, "problems": [], "failure": null, "images": [
          {"locale": "ja", "kind": "productPageHeader",
           "problems": [{"code": "outside-safe-area", "message": "header.title が安全領域の外にあります"}]},
          {"locale": "ja", "kind": "searchResults", "problems": []},
          {"locale": "en-US", "kind": "productPageHeader", "problems": []},
          {"locale": "en-US", "kind": "searchResults", "problems": []}
        ]}
        """#

    static var allImages: [String: Data] {
        [
            "ja/product-page-header.png": header, "ja/search-results.png": search,
            "en-US/product-page-header.png": header, "en-US/search-results.png": search
        ]
    }

    func temporaryOriginals() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("askhub-creative-test-\(UUID().uuidString)", isDirectory: true)
    }

    /// 案を頼み、Claude の案から書き出しの起動まで進める
    func draftAndDispatch(_ watch: CreativeWatch) async throws {
        let envelope = creativeEnvelope("draftCreativeAssets", revision: 0)
        let decision = try await DraftCreativeAssetsHandler().handle(envelope, in: creativeContext)
        #expect(decision == .accept)
        hosting.workflows.withLock { $0.dispatchReply = .success(DispatchedRun(id: Self.creativeRun, url: nil)) }
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
    }

    // MARK: - 受け付け

    @Test func acceptsCreativeDraftAndApprove() async throws {
        try await addRepository()
        let context = creativeContext
        let first = creativeEnvelope("draftCreativeAssets", revision: 0)
        #expect(try await DraftCreativeAssetsHandler().handle(first, in: context) == .accept)
        var file = try await creativeFile()
        #expect(file.draft?.revision == 1 && file.draft?.state == .drafting && file.draft?.request.comment == nil)
        // 同じ意図をもう一度処理しても同じ（やり直し）。見た版が古い頼みは断る
        #expect(try await DraftCreativeAssetsHandler().handle(first, in: context) == .accept)
        let stale = creativeEnvelope("draftCreativeAssets", revision: 0, nonce: 2)
        if case .reject = try await DraftCreativeAssetsHandler().handle(stale, in: context) {} else { Issue.record("古い版の頼みを受け付けた") }
        // 書き出しが終わっていない案は承認できない
        let early = creativeEnvelope("approveCreativeAssets", revision: 1)
        if case .reject = try await ApproveCreativeAssetsHandler().handle(early, in: context) {
        } else {
            Issue.record("書き出していない案を承認した")
        }

        // 書き出し終えた案を承認し、直してほしいことを書くと、今の案が前の案に移る
        let spec = CreativeProtocolFixtures.spec
        let images = CreativeKind.allCases.map { kind in
            CreativeFile.Image(
                locale: "ja",
                kind: kind,
                md5: String(repeating: "a", count: 32),
                preview: StatePath.creativePreview(Self.repo, revision: 1, locale: "ja", kind: kind)
            )
        }
        try await context.files.update(CreativeFile.self, at: StatePath.creative(Self.repo), message: "書き出した") { file in
            file.draft?.state = .rendered
            file.draft?.spec = spec
            file.draft?.images = images
            file.draft?.screenshotsRun = 44_000_000_001
            return true
        }
        let approve = creativeEnvelope("approveCreativeAssets", revision: 1, nonce: 3)
        #expect(try await ApproveCreativeAssetsHandler().handle(approve, in: context) == .accept)
        let revise = creativeEnvelope("draftCreativeAssets", revision: 1, payload: ["comment": .string("もっと短く")], nonce: 4)
        #expect(try await DraftCreativeAssetsHandler().handle(revise, in: context) == .accept)
        file = try await creativeFile()
        #expect(file.approved?.revision == 1 && file.approved?.images == images)
        #expect(file.previous?.revision == 1 && file.previous?.spec == spec)
        #expect(file.draft?.revision == 2 && file.draft?.state == .drafting && file.draft?.request.comment == "もっと短く")
        #expect(file.draft?.spec == nil && file.draft?.screenshotsRun == 44_000_000_001)
    }

    @Test func refusesCreativeDraftForUnknownRepository() async throws {
        let envelope = creativeEnvelope("draftCreativeAssets", revision: 0)
        let decision = try await DraftCreativeAssetsHandler().handle(envelope, in: creativeContext)
        if case .reject = decision {} else { Issue.record("対象でないリポジトリの頼みを受け付けた") }
    }

    // MARK: - 案と書き出し

    @Test func draftsRendersAndImportsCreative() async throws {
        try await prepareCreative()
        let drafter = FakeCreativeDrafter()
        let originals = temporaryOriginals()
        defer { try? FileManager.default.removeItem(at: originals) }
        let watch = creativeWatch(drafter: drafter, originals: originals)
        try await draftAndDispatch(watch)

        // Claude の材料は、配信中の版の言語・アプリ名・掲載文と既定のブランチの先頭
        let request = try #require(drafter.requests.withLock { $0.first })
        #expect(request.commit == Self.developHead && request.appName == "推し活カウントダウン")
        #expect(request.locales.map(\.locale) == ["en-US", "ja"] && request.locales.map(\.appName) == ["Oshi Countdown", "推し活カウントダウン"])
        #expect(request.previous == nil && request.comment == nil)
        var file = try await creativeFile()
        var draft = try #require(file.draft)
        #expect(draft.state == .rendering && draft.reason == "記念日を忘れないことを見出しにしました")
        #expect(draft.run?.id == Self.creativeRun && draft.run?.after == 0)
        let dispatch = try #require(hosting.workflows.withLock { $0.dispatches.first })
        #expect(dispatch.workflow == "app-store-creative.yml" && dispatch.ref == "develop")
        #expect(dispatch.inputs["screenshots_run"]?.isEmpty == true)
        let sent = try JSONDecoder().decode(CreativeSpec.self, from: Data(try #require(dispatch.inputs["spec"]).utf8))
        #expect(sent == draft.spec)

        // 終わった実行を取り込む
        creativeArtifacts(report: Self.cleanReport, files: Self.allImages)
        hosting.workflows.withLock { $0.runs[Self.creativeRun] = creativeRunDetail(status: "completed", conclusion: "success") }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()

        file = try await creativeFile()
        draft = try #require(file.draft)
        #expect(draft.state == .rendered && draft.awaitsReview)
        #expect(draft.images.count == 4 && draft.screenshotsRun == Self.creativeRun)
        #expect(draft.images.first { $0.locale == "ja" && $0.kind == .productPageHeader }?.problems.map(\.code) == ["outside-safe-area"])
        #expect(draft.run?.conclusion == "success")
        for image in draft.images {
            let preview = try #require(await store.data(at: image.preview))
            #expect(Data(base64Encoded: preview) != nil)
            let original = CreativeImport.original(
                in: originals.appendingPathComponent("\(Self.repo.owner)/\(Self.repo.name)/1"), locale: image.locale, kind: image.kind
            )
            #expect(CreativeImport.md5(try Data(contentsOf: original)) == image.md5)
        }
    }

    @Test func reusesCreativeScreenshotsOfThePreviousRun() async throws {
        try await prepareCreative()
        let drafter = FakeCreativeDrafter()
        let originals = temporaryOriginals()
        defer { try? FileManager.default.removeItem(at: originals) }
        // 前の案の書き出しで撮った 6.9 インチの画面が残っている
        try await creativeContext.files.create(
            CreativeFile(
                repo: Self.repo,
                draft: .init(
                    revision: 1,
                    request: .init(approval: .init(keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
                                                   nonce: ULID(rawValue: "01JCN0NCE00000000000000099")!), at: Timestamp(Self.now)),
                    state: .failed,
                    screenshotsRun: 45_000_000_001,
                    failure: "前の失敗"
                ),
                updatedAt: Timestamp(Self.now)
            ),
            at: StatePath.creative(Self.repo),
            message: "前の案"
        )
        hosting.workflows.withLock { state in
            state.artifacts[45_000_000_001] = [RunArtifact(id: 9, name: "screenshots-APP_IPHONE_67", size: 5_000_000, expired: false)]
            state.dispatchReply = .success(DispatchedRun(id: Self.creativeRun, url: nil))
        }
        let watch = creativeWatch(drafter: drafter, originals: originals)
        let decision = try await DraftCreativeAssetsHandler().handle(
            creativeEnvelope("draftCreativeAssets", revision: 1, payload: ["comment": .string("色を明るく")]), in: creativeContext
        )
        #expect(decision == .accept)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
        #expect(hosting.workflows.withLock { $0.dispatches.first?.inputs["screenshots_run"] } == "45000000001")
        #expect(drafter.requests.withLock { $0.first?.comment } == "色を明るく")
    }
}

/// 受け付けのテストで使う案
enum CreativeProtocolFixtures {
    static let spec = CreativeSpec(
        colors: .init(background: "#1B1036", accent: "#FF6FAE", text: "#FFFFFF"),
        screens: .init(header: ["01_home"], search: ["01_home"]),
        locales: [
            .init(
                locale: "ja",
                screenshots: "ja",
                appName: "推し活カウントダウン",
                header: .init(title: "記念日を忘れない"),
                search: .init(title: "予定をひと目で")
            )
        ]
    )
}
