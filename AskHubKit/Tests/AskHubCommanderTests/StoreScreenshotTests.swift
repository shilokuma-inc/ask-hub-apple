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
    static let iPhone = "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"
    static let duo = "IPHONE_DUO_PROFILE"
    static let japanese = StoreScreenshotTarget(displayType: iPhone, locale: "ja")
    static let english = StoreScreenshotTarget(displayType: iPhone, locale: "en-US")

    func addScreenshotRepository(displayTypes: [String: [String]] = [iPhone: ["iPhone 17 Pro Max"]]) async throws {
        var file = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        file.build = RepositoryFile.Build(
            xcode: try BuildSettings(project: "OshiCon.xcodeproj", scheme: "OshiCon", destinations: [.macOS]),
            childChecks: ["build / build"],
            finalChecks: ["build / build"],
            storeScreenshots: .uiTest(StoreScreenshotSettings(
                test: "OshiConUITests/AppStoreScreenshotTests",
                environment: ["APP_STORE_SCREENSHOTS": "1"],
                languageVariable: "APP_STORE_LANGUAGE",
                regionVariable: "APP_STORE_LOCALE",
                languages: ["ja": .init(language: "ja", region: "ja_JP"), "en-US": .init(language: "en", region: "en_US")],
                baseLocale: "ja",
                displayTypes: displayTypes
            ))
        )
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
    }

    /// 配信中の版の、言語ごとの iPhone 6.9 のスクショ（`images` の順）と、iPhone Duo の 1 枚。
    /// `askHubUploaded` なら AskHub が上げた画像（参照名に MD5 がある）、でなければほかで上げた画像（画素を比べる）
    func liveScreenshots(_ images: [Data], localization: String, locale: String, duo: Data = commanderPNG(), askHubUploaded: Bool = true) {
        func shots(_ images: [Data], prefix: String) -> [AppStoreScreenshot] {
            images.enumerated().map { offset, data in
                AppStoreScreenshot(
                    id: "\(prefix)-\(locale)-\(offset + 1)",
                    imageID: "image-\(prefix)-\(locale)-\(offset + 1)",
                    checksum: askHubUploaded ? AppStoreScreenshot.checksum(of: data) : nil,
                    imageURL: URL(string: "https://is1-ssl.mzstatic.com/\(prefix)/\(locale)/\(offset + 1).png")
                )
            }
        }
        let iPhoneShots = shots(images, prefix: "iphone"), duoShots = shots([duo], prefix: "duo")
        appStore.state.withLock { state in
            state.screenshotSets[localization] = [
                AppStoreScreenshotSet(displayType: Self.iPhone, screenshots: iPhoneShots),
                AppStoreScreenshotSet(displayType: Self.duo, screenshots: duoShots)
            ]
            for (shot, data) in zip(iPhoneShots + duoShots, images + [duo]) { state.images[shot.imageURL!] = data }
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
        #expect(changed.before == "https://is1-ssl.mzstatic.com/iphone/ja/2.png")
        #expect(changed.preview == StatePath.storeScreenshot(
            Self.repo, Self.next, commit: Self.developHead, shot: .init(displayType: Self.iPhone, locale: "ja", index: 2)
        ))
        let area = try #require(changed.area)
        #expect(area.x < 0.05 && area.y < 0.05 && area.x + area.width > 0.7 && area.y + area.height > 0.7)
        // 見本（JPEG を base64 にした文字）は状態リポジトリに、元の画像は常時オンの Mac に
        let stored = try #require(await store.data(at: changed.preview!))
        let jpeg = try #require(StatePath.storeScreenshotImage(stored, path: changed.preview!))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        let original = StoreScreenshotRun.original(
            in: capturer.originals(Self.repo, version: Self.next, commit: Self.developHead), target: Self.japanese, index: 2
        )
        #expect(FileManager.default.fileExists(atPath: original.path))
        // 撮り方に機種の無い表示サイズは、撮らずに知らせる
        #expect(shots.skipped == [.init(displayType: Self.duo, reason: StoreScreenshotRun.unconfiguredReason)])
    }

    @Test func capturesIPhoneDuoWhenConfigured() async throws {
        try await startRelease()
        try await addScreenshotRepository(displayTypes: [Self.iPhone: ["iPhone 17 Pro Max"], Self.duo: ["iPhone Duo"]])
        let home = commanderPNG(), folded = commanderPNG(mark: CGRect(x: 0, y: 0, width: 40, height: 40))
        liveScreenshots([home], localization: "l-ja", locale: "ja", duo: home)
        liveScreenshots([home], localization: "l-en", locale: "en-US", duo: home)
        let duo = StoreScreenshotTarget(displayType: Self.duo, locale: "ja")
        let capturer = FakeStoreScreenshots()
        capturer.images.withLock { $0 = [Self.japanese: [home], duo: [folded]] }
        let watch = watch(screenshots: capturer)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        let shots = try #require(try await submission().screenshots)
        // iPhone Duo も基準の言語で撮る（Duo に差があったので英語も撮りに行く）
        #expect(capturer.requests.withLock { $0.first } == [duo, Self.japanese])
        #expect(shots.sets.first { $0.displayType == Self.duo && $0.locale == "ja" }?.isChanged == true)
        #expect(!shots.skipped.contains { $0.displayType == Self.duo && $0.reason == StoreScreenshotRun.unconfiguredReason })
    }

    @Test func comparesPixelsOfScreenshotsUploadedElsewhere() async throws {
        try await startRelease()
        try await addScreenshotRepository()
        let home = commanderPNG()
        // OshiCon の前の仕組みなど、AskHub の外で上げた画像（参照名に MD5 が無い）は、取ってきて画素を比べる
        liveScreenshots([home], localization: "l-ja", locale: "ja", askHubUploaded: false)
        liveScreenshots([home], localization: "l-en", locale: "en-US", askHubUploaded: false)
        let capturer = FakeStoreScreenshots()
        capturer.images.withLock { $0 = [Self.japanese: [home]] }
        let watch = watch(screenshots: capturer)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.sets.count == 1 && !shots.sets[0].isChanged)
        // 基準の言語に差が無いので、ほかの言語は撮らない
        #expect(capturer.requests.withLock { $0 } == [[Self.japanese]])
        // 前に配信した版のタグから release ブランチの先頭までの文言の差を見た
        #expect(sources.state.withLock { $0.localizationRanges } == ["v1.0.0..\(Self.developHead)"])
    }

    @Test func capturesLocalesWhoseWordingChangedEvenIfTheBaseIsUnchanged() async throws {
        try await startRelease()
        try await addScreenshotRepository()
        let home = commanderPNG(), renamed = commanderPNG(mark: CGRect(x: 0, y: 70, width: 40, height: 10))
        liveScreenshots([home], localization: "l-ja", locale: "ja")
        liveScreenshots([home], localization: "l-en", locale: "en-US")
        // アプリの英語（en-US の language）の文言だけが変わった
        sources.state.withLock { $0.localizations = LocalizationChanges(languages: ["en", "fr"]) }
        let capturer = FakeStoreScreenshots()
        capturer.images.withLock { $0 = [Self.japanese: [home], Self.english: [renamed]] }
        let watch = watch(screenshots: capturer)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        let shots = try #require(try await submission().screenshots)
        #expect(capturer.requests.withLock { $0 } == [[Self.japanese], [Self.english]])
        #expect(shots.state == .captured && shots.sets.map(\.locale) == ["ja", "en-US"])
        #expect(shots.sets.map(\.isChanged) == [false, true])
    }

    @Test func capturesEveryLocaleWithoutPreviousTag() async throws {
        try await startRelease()
        try await addScreenshotRepository()
        let home = commanderPNG()
        liveScreenshots([home], localization: "l-ja", locale: "ja")
        liveScreenshots([home], localization: "l-en", locale: "en-US")
        // 前の版のタグが無いと、どの言語の文言が変わったか分からない
        sources.state.withLock { $0.changes.previousTag = nil }
        let capturer = FakeStoreScreenshots()
        capturer.images.withLock { $0 = [Self.japanese: [home], Self.english: [home]] }
        let watch = watch(screenshots: capturer)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        #expect(capturer.requests.withLock { $0 } == [[Self.japanese], [Self.english]])
        #expect(sources.state.withLock { $0.localizationRanges }.isEmpty)
        #expect(try await submission().screenshots?.sets.contains(where: \.isChanged) == false)
    }

    @Test func failsWhenLiveScreenshotsAreNotReadableAsPlacements() async throws {
        try await startRelease()
        try await addScreenshotRepository()
        let capturer = FakeStoreScreenshots()
        capturer.images.withLock { $0 = [Self.japanese: [commanderPNG()]] }
        let watch = watch(screenshots: capturer)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        let shots = try #require(try await submission().screenshots)
        // 配信中の版に配置のスクショが無ければ、比べられないので撮らずに failed（スクショを変えずに審査に出せる）
        #expect(shots.state == .failed && shots.failure?.contains("App Asset Library") == true)
        #expect(capturer.requests.withLock { $0 }.isEmpty)
    }

    /// 撮った元の画像を置き、2・3 枚目に差がある記録で、審査に出せるようにする（`keep` は前のままにする位置。既定は 3 枚目）。
    /// 配信中の版（l-ja）と編集できる版（e-ja）の配置は、どちらも画像 i1〜i4。撮ったときの Before は配信中の版の画像の URL
    func readyToSubmitScreenshots(keep: [Int] = [3]) async throws -> (originals: URL, capturer: FakeStoreScreenshots) {
        var file = try await readyToSubmit()
        let capturer = FakeStoreScreenshots()
        let originals = capturer.originals(Self.repo, version: Self.next, commit: Self.developHead)
        for index in [2, 3] {
            let url = StoreScreenshotRun.original(in: originals, target: Self.japanese, index: index)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try commanderPNG(mark: CGRect(x: index, y: index, width: 5, height: 5)).write(to: url)
        }
        let preview = StatePath.storeScreenshot(
            Self.repo, Self.next, commit: Self.developHead, shot: .init(displayType: Self.iPhone, locale: "ja", index: 2)
        )
        let shots: [SubmissionFile.Shot] = [
            .init(index: 1, name: "01", changed: false, before: Self.liveImage(1).absoluteString),
            .init(index: 2, name: "02", changed: true, preview: preview, before: Self.liveImage(2).absoluteString),
            .init(index: 3, name: "03", changed: true, preview: preview, before: Self.liveImage(3).absoluteString)
        ]
        file.screenshots = .init(
            state: .captured,
            commit: Self.developHead,
            startedAt: file.createdAt,
            finishedAt: file.createdAt,
            sets: [
                .init(displayType: Self.iPhone, locale: "ja", shots: shots, removed: 1),
                // Mac の版に載る表示サイズは、iOS の版には書かない
                .init(displayType: "MAC_PROFILE", locale: "ja", shots: [.init(index: 1, name: "01", changed: true, preview: preview)])
            ]
        )
        file.submit?.screenshots = .init(
            commit: Self.developHead, keep: keep.map { .init(displayType: Self.iPhone, locale: "ja", index: $0) }
        )
        try await putSubmission(file)
        let placements = { @Sendable (prefix: String) -> [AppStoreScreenshotSet] in
            let shots = (1...4).map { index in
                AppStoreScreenshot(id: "\(prefix)-p\(index)", imageID: "i\(index)", checksum: nil, imageURL: Self.liveImage(index))
            }
            return [AppStoreScreenshotSet(displayType: Self.iPhone, screenshots: shots)]
        }
        appStore.state.withLock { state in
            // 編集できる版の言語は、配信中の版と別の id
            state.localizations["v-1-2-0"] = (state.localizations["v-1-2-0"] ?? []).map { localization in
                var localization = localization
                localization.id = "e" + localization.id.dropFirst()
                return localization
            }
            state.screenshotSets["l-ja"] = placements("l")
            state.screenshotSets["e-ja"] = placements("e")
        }
        return (originals, capturer)
    }

    /// 配信中の版の画像 i<n> の URL
    static func liveImage(_ index: Int) -> URL {
        URL(string: "https://is1-ssl.mzstatic.com/i\(index)/1320x2868bb.png")!
    }

    func screenshotWrites() -> [String] {
        let kinds = ["uploadImage", "deleteImage", "placeScreenshot", "deletePlacement", "orderScreenshots"]
        return appStore.state.withLock { $0.writes }.filter { write in kinds.contains { write.hasPrefix($0) } }
    }

    @Test func placesAcceptedScreenshotsAtSubmit() async throws {
        let (_, capturer) = try await readyToSubmitScreenshots()
        await watch(screenshots: capturer).refresh()
        let uploaded = "image-\(Self.iPhone)-ja-2.png"
        // 1・3 枚目は配信中の版の画像（i1・i3）の配置を残し、2 枚目を上げて置き、4 枚目（撮ったものより後ろ）を消す
        #expect(screenshotWrites() == [
            "uploadImage \(Self.iPhone)-ja-2.png",
            "deletePlacement e-p2",
            "deletePlacement e-p4",
            "placeScreenshot \(uploaded) e-ja",
            "orderScreenshots e-ja e-p1,placement-1,e-p3"
        ])
    }

    @Test func resumesAPartialScreenshotWrite() async throws {
        let (originals, capturer) = try await readyToSubmitScreenshots()
        let data = try Data(contentsOf: StoreScreenshotRun.original(in: originals, target: Self.japanese, index: 2))
        let name = AppStoreScreenshot.referenceName(checksum: AppStoreScreenshot.checksum(of: data))
        appStore.state.withLock { state in
            // 前の試行が、2 枚目を上げて置き、古い配置を消したところで止まった（並べ直していない）
            state.libraryImages[name] = [AppStoreLibraryImage(id: "image-done", state: "PREPARE_FOR_SUBMISSION")]
            state.screenshotSets["e-ja"] = [
                AppStoreScreenshotSet(displayType: Self.iPhone, screenshots: [
                    AppStoreScreenshot(id: "e-p1", imageID: "i1", checksum: nil, imageURL: nil),
                    AppStoreScreenshot(id: "e-p3", imageID: "i3", checksum: nil, imageURL: nil),
                    AppStoreScreenshot(id: "e-new", imageID: "image-done", checksum: nil, imageURL: nil)
                ])
            ]
        }
        await watch(screenshots: capturer).refresh()
        // 上げ直さず、配置も作らず、並べ直すだけ
        #expect(screenshotWrites() == ["orderScreenshots e-ja e-p1,e-new,e-p3"])
    }

    @Test func replacesFailedUploadsOfTheSameImage() async throws {
        let (originals, capturer) = try await readyToSubmitScreenshots()
        let data = try Data(contentsOf: StoreScreenshotRun.original(in: originals, target: Self.japanese, index: 2))
        let name = AppStoreScreenshot.referenceName(checksum: AppStoreScreenshot.checksum(of: data))
        appStore.state.withLock { $0.libraryImages[name] = [AppStoreLibraryImage(id: "image-failed", state: "FAILED")] }
        await watch(screenshots: capturer).refresh()
        #expect(screenshotWrites().prefix(2) == ["deleteImage image-failed", "uploadImage \(Self.iPhone)-ja-2.png"])
    }

    @Test func placesLiveImagesWhenEveryChangedScreenIsKept() async throws {
        let (_, capturer) = try await readyToSubmitScreenshots(keep: [2, 3])
        // 編集できる版の 2 枚目に、やめた前のリリースで上げた画像が残っている
        appStore.state.withLock { state in
            let left = AppStoreScreenshot(id: "e-left", imageID: "image-left", checksum: nil, imageURL: nil)
            state.screenshotSets["e-ja"]?[0].screenshots[1] = left
        }
        await watch(screenshots: capturer).refresh()
        // すべて前のままにした組も、配信中の版の画像（i1〜i3）にそろえ、撮ったものより後ろの 4 枚目を消す
        #expect(screenshotWrites() == [
            "deletePlacement e-left",
            "deletePlacement e-p4",
            "placeScreenshot i2 e-ja",
            "orderScreenshots e-ja e-p1,placement-1,e-p3"
        ])
    }

    @Test func stopsWhenLiveScreenshotsChangedAfterCapture() async throws {
        let (_, capturer) = try await readyToSubmitScreenshots()
        // 撮って比べた後に、配信中の版の 3 枚目（前のままにする位置）が別の画像になった
        appStore.state.withLock { state in
            state.screenshotSets["l-ja"]?[0].screenshots[2] = AppStoreScreenshot(
                id: "l-new", imageID: "i9", checksum: nil, imageURL: URL(string: "https://is1-ssl.mzstatic.com/i9/1320x2868bb.png")
            )
        }
        await watch(screenshots: capturer).refresh()
        // 人が Before で見ていない画像は置かずに、上げる前に止める
        #expect(screenshotWrites().isEmpty)
        let file = try await submission()
        #expect(file.problem?.step == .submit && file.problem?.needsHuman == true)
        #expect(file.problem?.message.contains("撮って比べた後に変わった") == true)
    }

    @Test func checksEverySetBeforeWritingAny() async throws {
        let (_, capturer) = try await readyToSubmitScreenshots()
        // 日本語の組（書く必要がある）の後に、英語の組（1 枚目を前のままにする）がある
        var file = try await submission()
        let before = Self.liveImage(1).absoluteString
        let preview = StatePath.storeScreenshot(
            Self.repo, Self.next, commit: Self.developHead, shot: .init(displayType: Self.iPhone, locale: "en-US", index: 1)
        )
        file.screenshots?.sets.append(.init(
            displayType: Self.iPhone, locale: "en-US", shots: [.init(index: 1, name: "01", changed: true, preview: preview, before: before)]
        ))
        file.submit?.screenshots?.keep.append(.init(displayType: Self.iPhone, locale: "en-US", index: 1))
        try await putSubmission(file)
        appStore.state.withLock { state in
            // 英語の組の配信中の 1 枚目だけが、撮って比べた後に別の画像になった
            let changed = AppStoreScreenshot(
                id: "l-en-new", imageID: "i9", checksum: nil, imageURL: URL(string: "https://is1-ssl.mzstatic.com/i9/1320x2868bb.png")
            )
            state.screenshotSets["l-en"] = [AppStoreScreenshotSet(displayType: Self.iPhone, screenshots: [changed])]
        }
        await watch(screenshots: capturer).refresh()
        // 後の組で止まるので、先の日本語の組も書かない
        #expect(screenshotWrites().isEmpty)
        #expect(try await submission().problem?.message.contains("en-US の 1 枚目") == true)
    }
}
