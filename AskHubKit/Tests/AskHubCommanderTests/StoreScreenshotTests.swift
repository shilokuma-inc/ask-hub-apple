import AskHubBuild
@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CoreGraphics
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers

/// 決めた画像を返し、頼まれた組を残す撮影の道具
final class FakeStoreScreenshots: StoreScreenshotCapturing {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("store-screenshots-\(UUID().uuidString)", isDirectory: true)
    let images = OSAllocatedUnfairLock<[StoreScreenshotTarget: [Data]]>(initialState: [:])
    let requests = OSAllocatedUnfairLock<[[StoreScreenshotTarget]]>(initialState: [])

    func capture(
        _ request: StoreScreenshotCaptureRequest
    ) async throws(CancellationError) -> [StoreScreenshotTarget: Result<[CapturedShot], CaptureFailure>] {
        requests.withLock { $0.append(request.targets) }
        var results: [StoreScreenshotTarget: Result<[CapturedShot], CaptureFailure>] = [:]
        for target in request.targets {
            guard let datas = images.withLock({ $0[target] }) else {
                results[target] = .failure(CaptureFailure("UI テストが通らない"))
                continue
            }
            let directory = root.appendingPathComponent("runs/\(target.displayType)/\(target.locale)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            results[target] = .success(datas.enumerated().map { offset, data in
                let file = directory.appendingPathComponent("\(offset + 1).png")
                try? data.write(to: file)
                return CapturedShot(name: String(format: "%02d-画面", offset + 1), file: file)
            })
        }
        return results
    }

    func originals(_ repo: RepositoryFullName, version: MarketingVersion, commit: String) -> URL {
        root.appendingPathComponent("originals/\(commit)", isDirectory: true)
    }
}

/// 白地に、上から `mark` の所だけ赤く塗った PNG
func commanderPNG(mark: CGRect? = nil) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(data: nil, width: 40, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alpha)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
    if let mark {
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: mark.minX, y: 80 - mark.maxY, width: mark.width, height: mark.height))
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// リリースを始めた版の App Store のスクショ: 撮って比べる・審査に出すときに上げる
extension ReleaseWatchTests {
    static let iPhone = "APP_IPHONE_67"
    static let japanese = StoreScreenshotTarget(displayType: iPhone, locale: "ja")
    static let english = StoreScreenshotTarget(displayType: iPhone, locale: "en-US")

    func addScreenshotRepository() async throws {
        var file = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        file.build = RepositoryFile.Build(
            xcode: try BuildSettings(project: "OshiCon.xcodeproj", scheme: "OshiCon", destinations: [.macOS]),
            childChecks: ["build / build"],
            finalChecks: ["build / build"],
            storeScreenshots: StoreScreenshotSettings(
                test: "OshiConUITests/AppStoreScreenshotTests",
                environment: ["APP_STORE_SCREENSHOTS": "1"],
                languageVariable: "APP_STORE_LANGUAGE",
                regionVariable: "APP_STORE_LOCALE",
                languages: ["ja": .init(language: "ja", region: "ja_JP"), "en-US": .init(language: "en", region: "en_US")],
                baseLocale: "ja",
                displayTypes: [Self.iPhone: ["iPhone 17 Pro Max"]]
            )
        )
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
    }

    /// 配信中の版の、言語ごとのスクショ（`images` の順）。iPhone Duo の組もある
    func liveScreenshots(_ images: [Data], localization: String, locale: String) {
        let shots = images.enumerated().map { offset, data in
            AppStoreScreenshot(
                id: "\(locale)-\(offset + 1)",
                checksum: AppStoreScreenshot.checksum(of: data),
                imageURL: URL(string: "https://is1-ssl.mzstatic.com/\(locale)/\(offset + 1).png")
            )
        }
        appStore.state.withLock { state in
            state.screenshotSets[localization] = [
                AppStoreScreenshotSet(id: "set-\(locale)", displayType: Self.iPhone, screenshots: shots),
                AppStoreScreenshotSet(id: "duo-\(locale)", displayType: "APP_IPHONE_DUO", screenshots: [])
            ]
            for (shot, data) in zip(shots, images) { state.images[shot.imageURL!] = data }
        }
    }

    @Test func capturesBaseLocaleFirstAndComparesWithAppStore() async throws {
        try await startRelease()
        try await addScreenshotRepository()
        let home = commanderPNG(), detail = commanderPNG(mark: CGRect(x: 0, y: 0, width: 10, height: 10))
        let newDetail = commanderPNG(mark: CGRect(x: 20, y: 40, width: 10, height: 20))
        liveScreenshots([home, detail], localization: "l-ja", locale: "ja")
        liveScreenshots([home, detail], localization: "l-en", locale: "en-US")
        let capturer = FakeStoreScreenshots()
        capturer.images.withLock { $0 = [Self.japanese: [home, newDetail], Self.english: [home, newDetail]] }
        let watch = watch(screenshots: capturer)
        await watch.refresh()
        #expect(try await submission().screenshots?.state == .capturing)
        await watch.waitForScreenshotCaptures()

        let file = try await submission()
        let shots = try #require(file.screenshots)
        #expect(shots.state == .captured && shots.commit == Self.developHead)
        // 基準の言語を先に撮り、差があったので英語も撮る
        #expect(capturer.requests.withLock { $0 } == [[Self.japanese], [Self.english]])
        let japanese = try #require(shots.sets.first { $0.locale == "ja" })
        #expect(japanese.shots.map(\.changed) == [false, true])
        let changed = japanese.shots[1]
        #expect(changed.before == "https://is1-ssl.mzstatic.com/ja/2.png")
        #expect(changed.preview == StatePath.storeScreenshot(Self.repo, Self.next, displayType: Self.iPhone, locale: "ja", index: 2))
        let area = try #require(changed.area)
        #expect(area.x < 0.05 && area.y < 0.05 && area.x + area.width > 0.7 && area.y + area.height > 0.7)
        // 見本は状態リポジトリに、元の画像は常時オンの Mac に
        #expect(await store.data(at: changed.preview!) != nil)
        let original = StoreScreenshotRun.original(
            in: capturer.originals(Self.repo, version: Self.next, commit: Self.developHead), target: Self.japanese, index: 2
        )
        #expect(FileManager.default.fileExists(atPath: original.path))
        // iPhone Duo は撮らずに知らせる
        #expect(shots.skipped.map(\.displayType) == ["APP_IPHONE_DUO"])
    }

    @Test func skipsOtherLocalesWhenTheBaseIsUnchanged() async throws {
        try await startRelease()
        try await addScreenshotRepository()
        let home = commanderPNG()
        liveScreenshots([home], localization: "l-ja", locale: "ja")
        liveScreenshots([home], localization: "l-en", locale: "en-US")
        let capturer = FakeStoreScreenshots()
        capturer.images.withLock { $0 = [Self.japanese: [home]] }
        let watch = watch(screenshots: capturer)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.sets.count == 1 && !shots.sets[0].isChanged)
        #expect(capturer.requests.withLock { $0 } == [[Self.japanese]])
    }

    @Test func uploadsAcceptedScreenshotsAtSubmit() async throws {
        var file = try await readyToSubmit()
        let capturer = FakeStoreScreenshots()
        let originals = capturer.originals(Self.repo, version: Self.next, commit: Self.developHead)
        for index in [2, 3] {
            let url = StoreScreenshotRun.original(in: originals, target: Self.japanese, index: index)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try commanderPNG(mark: CGRect(x: index, y: index, width: 5, height: 5)).write(to: url)
        }
        let preview = StatePath.storeScreenshot(Self.repo, Self.next, displayType: Self.iPhone, locale: "ja", index: 2)
        let shots: [SubmissionFile.Shot] = [
            .init(index: 1, name: "01", changed: false),
            .init(index: 2, name: "02", changed: true, preview: preview),
            .init(index: 3, name: "03", changed: true, preview: preview)
        ]
        file.screenshots = .init(
            state: .captured,
            commit: Self.developHead,
            startedAt: file.createdAt,
            finishedAt: file.createdAt,
            sets: [.init(displayType: Self.iPhone, locale: "ja", shots: shots, removed: 1)]
        )
        // 3 枚目は前のままにする
        file.submit?.screenshots = .init(commit: Self.developHead, keep: [.init(displayType: Self.iPhone, locale: "ja", index: 3)])
        try await putSubmission(file)
        let current = (1...4).map { AppStoreScreenshot(id: "s\($0)", checksum: "old\($0)", imageURL: nil) }
        let set = AppStoreScreenshotSet(id: "set-ja", displayType: Self.iPhone, screenshots: current)
        appStore.state.withLock { $0.screenshotSets["l-ja"] = [set] }
        await watch(screenshots: capturer).refresh()
        let writes = appStore.state.withLock { $0.writes }.filter { $0.contains("Screenshot") }
        #expect(writes == [
            "uploadScreenshot set-ja APP_IPHONE_67-ja-2.png",
            "deleteScreenshot s2",
            "deleteScreenshot s4",
            "orderScreenshots set-ja s1,new-APP_IPHONE_67-ja-2.png,s3"
        ])
    }
}
