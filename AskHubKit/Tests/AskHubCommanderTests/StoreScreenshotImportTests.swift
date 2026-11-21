@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import CoreGraphics
import Foundation
import Testing

/// artifact の代わり。zip の代わりに「言語のフォルダ → 画像」の JSON を受け取り、`01.png`・`02.png`… として書き出す
struct FakeArtifactExtractor: StoreScreenshotArtifactExtracting {
    static func zip(_ folders: [String: [Data]]) -> Data {
        (try? JSONEncoder().encode(folders)) ?? Data()
    }

    func extract(_ zip: Data, into directory: URL) async throws -> [String: [URL]] {
        let folders = try JSONDecoder().decode([String: [Data]].self, from: zip)
        var result: [String: [URL]] = [:]
        for (folder, images) in folders {
            let base = directory.appendingPathComponent("files/\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            result[folder] = try images.enumerated().map { offset, data in
                let file = base.appendingPathComponent(String(format: "%02d.png", offset + 1))
                try data.write(to: file)
                return file
            }
        }
        return result
    }
}

/// リポジトリの撮影のワークフローで撮る App Store のスクショ（`capture: actions`）: 終わった実行の artifact を取り込んで比べる
extension ReleaseWatchTests {
    static let home = commanderPNG()
    static let detail = commanderPNG(mark: CGRect(x: 0, y: 0, width: 10, height: 10))
    static let newDetail = commanderPNG(mark: CGRect(x: 20, y: 40, width: 10, height: 20))

    /// 撮影の実行の artifact（6.9 インチと iPhone Duo）
    func screenshotArtifacts(iPhone: [String: [Data]], duo: [String: [Data]]? = nil) {
        hosting.workflows.withLock { state in
            var artifacts = [RunArtifact(id: 1, name: "screenshots-APP_IPHONE_67", size: 5_000_000, expired: false)]
            state.zips[1] = FakeArtifactExtractor.zip(iPhone)
            if let duo {
                artifacts.append(RunArtifact(id: 2, name: "screenshots-APP_IPHONE_DUO", size: 4_000_000, expired: false))
                state.zips[2] = FakeArtifactExtractor.zip(duo)
            }
            // ほかの実行・ほかの名前の artifact は使わない
            artifacts.append(RunArtifact(id: 3, name: "logs", size: 100, expired: false))
            state.artifacts[Self.screenshotRun] = artifacts
        }
    }

    /// 起動して、実行を終わらせ、取り込み終えるまで見回る
    func captureOnActions(_ watch: ReleaseWatch, conclusion: String = "success") async {
        await watch.refresh()
        hosting.workflows.withLock {
            $0.runs[Self.screenshotRun] = screenshotRun(status: "completed", conclusion: conclusion)
        }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
    }

    @Test func importsArtifactsAndComparesEveryLocaleWithTheLiveVersion() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home, Self.detail], localization: "l-ja", locale: "ja", duo: Self.home)
        liveScreenshots([Self.home, Self.detail], localization: "l-en", locale: "en-US", duo: Self.home)
        screenshotArtifacts(
            iPhone: ["ja": [Self.home, Self.newDetail], "en": [Self.home, Self.detail]],
            duo: ["ja": [Self.home], "en": [Self.home]]
        )
        let capturer = FakeStoreScreenshots()
        let watch = watch(screenshots: capturer)
        await captureOnActions(watch)

        let file = try await submission()
        let shots = try #require(file.screenshots)
        // 実行が撮ったコミットで比べる
        #expect(shots.state == .captured && shots.commit == Self.releaseHead && shots.run?.conclusion == "success")
        // 基準の言語の組が先。基準の言語に差が無くても、ほかの言語もすべて比べる
        #expect(shots.sets.map { "\($0.displayType)/\($0.locale)" } == [
            "\(Self.duo)/ja", "\(Self.iPhone)/ja", "\(Self.duo)/en-US", "\(Self.iPhone)/en-US"
        ])
        let japanese = try #require(shots.sets.first { $0.displayType == Self.iPhone && $0.locale == "ja" })
        #expect(japanese.shots.map(\.changed) == [false, true] && japanese.shots.map(\.name) == ["01", "02"])
        #expect(shots.sets.filter { $0 != japanese }.allSatisfy { !$0.isChanged })
        // 見本は撮ったコミットのパスに、base64 の文字で
        let changed = japanese.shots[1]
        let path = StatePath.storeScreenshot(
            Self.repo, Self.next, commit: Self.releaseHead, shot: .init(displayType: Self.iPhone, locale: "ja", index: 2)
        )
        #expect(changed.preview == path && changed.before == "https://is1-ssl.mzstatic.com/iphone/ja/2.png")
        let stored = try #require(await store.data(at: path))
        #expect(StatePath.storeScreenshotImage(stored, path: path)?.starts(with: [0xFF, 0xD8]) == true)
        // 元の画像は常時オンの Mac に（審査に出すときに上げる）
        let original = StoreScreenshotRun.original(
            in: capturer.originals(Self.repo, version: Self.next, commit: Self.releaseHead), target: Self.japanese, index: 2
        )
        #expect(try Data(contentsOf: original) == Self.newDetail)
        #expect(shots.skipped.isEmpty)
        #expect(await watch.capturing.isEmpty)
    }

    @Test func showsEveryShotAsNewForTheFirstVersion() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        // 配信中の版が無い（初めての版）
        appStore.state.withLock { $0.versions = [] }
        screenshotArtifacts(iPhone: ["ja": [Self.home, Self.detail], "en": [Self.home, Self.detail]])
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)

        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured)
        #expect(shots.sets.map { "\($0.displayType)/\($0.locale)" } == ["\(Self.iPhone)/ja", "\(Self.iPhone)/en-US"])
        #expect(shots.sets.allSatisfy { set in set.shots.allSatisfy { $0.changed && $0.before == nil && $0.preview != nil } })
        // artifact の無い表示サイズは、撮らなかったわけを出す
        #expect(shots.skipped.map(\.displayType) == [Self.duo])
        #expect(shots.skipped.first?.reason.contains("screenshots-APP_IPHONE_DUO") == true)
    }

    @Test func treatsALiveSetMissingFromTheLiveVersionAsNew() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        // 配信中の版に iPhone Duo の組が無い（はじめて Duo を撮る）
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        appStore.state.withLock { state in
            for key in ["l-ja", "l-en"] { state.screenshotSets[key]?.removeAll { $0.displayType == Self.duo } }
        }
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]], duo: ["ja": [Self.home], "en": [Self.home]])
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)

        let shots = try #require(try await submission().screenshots)
        let duo = try #require(shots.sets.first { $0.displayType == Self.duo && $0.locale == "ja" })
        #expect(duo.shots.map(\.changed) == [true] && duo.shots[0].before == nil)
        #expect(shots.sets.first { $0.displayType == Self.iPhone && $0.locale == "ja" }?.isChanged == false)
    }

    @Test func failsWhenTheBaseLocaleCannotBeImported() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        // 撮影のジョブがすべて失敗して、artifact が無い
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch, conclusion: "failure")

        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .failed && shots.failure?.contains("screenshots-") == true)
    }

    @Test func failsWithoutAPlaceForTheOriginals() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        screenshotArtifacts(iPhone: ["ja": [Self.home]])
        // スクショを撮る道具（元の画像を置く場所）が無い司令塔
        let watch = watch()
        await captureOnActions(watch)
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .failed && shots.failure?.contains("置く場所") == true)
    }
}
