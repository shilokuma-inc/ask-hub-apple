@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CoreGraphics
import Foundation
import Testing

/// 撮って比べた画像を、人が確かめる前に App Store Connect のライブラリに上げておき、取り込みを見回りの周で待つ
extension ReleaseWatchTests {
    /// Actions で撮り、日本語の 2 枚目だけに差がある記録にする（Apple の処理は `sentState` のまま止まる）
    func captureWithLibrary(sentState: String) async throws -> (ReleaseWatch, String) {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home, Self.detail], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home, Self.detail], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home, Self.newDetail], "en": [Self.home, Self.detail]])
        appStore.state.withLock { $0.sentState = sentState }
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)
        return (watch, AppStoreScreenshot.referenceName(checksum: AppStoreScreenshot.checksum(of: Self.newDetail)))
    }

    func libraryWrites() -> [String] {
        appStore.state.withLock { $0.writes }.filter { $0.hasPrefix("sendImage") || $0.hasPrefix("deleteImage") }
    }

    @Test func waitsForTheLibraryBeforeTheReleaseIsReady() async throws {
        let (watch, name) = try await captureWithLibrary(sentState: "UPLOAD_COMPLETE")
        var file = try await submission()
        // 差のある画面の元の画像を上げた（配置はしない）。Apple が処理している間は、撮影は決着せず、審査に出す準備もそろわない
        #expect(libraryWrites() == ["sendImage \(Self.iPhone)-ja-2.png"])
        #expect(file.screenshots?.state == .capturing && file.screenshots?.library?.total == 1 && file.screenshots?.library?.ready == 0)
        #expect(file.screenshots?.sets.first { $0.locale == "ja" }?.isChanged == true)
        #expect(!file.isPrepared)
        let revision = file.revision

        // 5 分たつまで読まない。処理中の画像は消さず、上げ直さない
        clock.advance(minutes: 5)
        await watch.refresh()
        #expect(libraryWrites().count == 1)
        #expect(try await submission().screenshots?.state == .capturing)

        appStore.setLibraryState(name, "PREPARE_FOR_SUBMISSION")
        clock.advance(minutes: 5)
        await watch.refresh()
        file = try await submission()
        #expect(file.screenshots?.state == .captured && file.screenshots?.library?.ready == 1)
        #expect(file.revision > revision)
        #expect(libraryWrites().count == 1)
    }

    @Test func marksScreensThatAppStoreConnectRejected() async throws {
        let (watch, name) = try await captureWithLibrary(sentState: "UPLOAD_COMPLETE")
        appStore.setLibraryState(name, "FAILED", details: "IMAGE_INCORRECT_DIMENSIONS")
        clock.advance(minutes: 5)
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        // 受け付けられなかった画面は、前のままにするしかない。撮影は決着し、審査に出せる
        #expect(shots.state == .captured && shots.library?.ready == 0)
        let rejected = shots.sets.first { $0.locale == "ja" }?.shots.first { $0.index == 2 }?.rejected
        #expect(rejected?.contains("IMAGE_INCORRECT_DIMENSIONS") == true)
    }

    @Test func givesUpOnTheLibraryAfterThreeHours() async throws {
        let (watch, _) = try await captureWithLibrary(sentState: "UPLOAD_COMPLETE")
        clock.advance(minutes: 3 * 60)
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured)
        #expect(shots.sets.flatMap(\.shots).contains { $0.rejected?.contains("3 時間") == true })
    }

    @Test func doesNotWaitWhenNothingChanged() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]])
        appStore.state.withLock { $0.sentState = "UPLOAD_COMPLETE" }
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.library == nil && libraryWrites().isEmpty)
    }

    @Test func keepsRejectedScreensAtSubmit() async throws {
        let (originals, capturer) = try await readyToSubmitScreenshots(keep: [])
        // 2 枚目は App Store Connect が受け付けなかった。人が「前のままにする」を選ばなくても、配信中の版の画像を置く
        var file = try await submission()
        file.screenshots?.sets[0].shots[1].rejected = "App Store Connect が受け付けなかった（IMAGE_INCORRECT_DIMENSIONS）"
        try await putSubmission(file)
        await watch(screenshots: capturer).refresh()
        let third = try Data(contentsOf: StoreScreenshotRun.original(in: originals, target: Self.japanese, index: 3))
        let sent = appStore.state.withLock { $0.writes }.filter { $0.hasPrefix("sendImage") }
        #expect(sent == ["sendImage \(Self.iPhone)-ja-3.png"])
        let name = AppStoreScreenshot.referenceName(checksum: AppStoreScreenshot.checksum(of: third))
        #expect(appStore.state.withLock { $0.libraryImages.keys.contains(name) })
    }

    @Test func rejectsScreensWhoseOriginalCannotBeRead() async throws {
        _ = try await captureWithLibrary(sentState: "UPLOAD_COMPLETE")
        // 撮った元の画像が、常時オンの Mac に無い（別の置き場所の撮影の道具で見回る）
        let moved = watch(screenshots: FakeStoreScreenshots())
        clock.advance(minutes: 5)
        await moved.refresh()
        let shots = try #require(try await submission().screenshots)
        let rejected = shots.sets.first { $0.locale == "ja" }?.shots.first { $0.index == 2 }?.rejected
        #expect(shots.state == .captured && rejected?.contains("読めない") == true)
    }

    @Test func countsTheProcessingTimeFromWhenTheImagesWereSent() async throws {
        let (watch, name) = try await captureWithLibrary(sentState: "UPLOAD_COMPLETE")
        // 送ったはずの画像がライブラリに無い（司令塔が止まっている間に消えた）。3 時間たっていても、送り直したところから数え直す
        appStore.state.withLock { _ = $0.libraryImages.removeValue(forKey: name) }
        clock.advance(minutes: 3 * 60)
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .capturing && shots.library?.sentAt == Timestamp(clock.now))
        #expect(libraryWrites().filter { $0.hasPrefix("sendImage") }.count == 2)
    }

    @Test func keepsTheSendTimeEvenIfTheSentImageCannotBeRead() async throws {
        let (watch, name) = try await captureWithLibrary(sentState: "UPLOAD_COMPLETE")
        // 待ち始めて 2 時間 55 分後に送り直し、その直後に送った画像の様子を読めなかった
        appStore.state.withLock {
            _ = $0.libraryImages.removeValue(forKey: name)
            $0.sentImageFailure = .unavailable("503")
        }
        clock.advance(minutes: 2 * 60 + 55)
        await watch.refresh()
        var file = try await submission()
        #expect(file.screenshots?.state == .capturing && file.screenshots?.library?.sentAt == Timestamp(clock.now))
        #expect(file.problem == nil)
        // 次の周（待ち始めて 3 時間を過ぎた）も、送り直したところから数えるので打ち切らない
        appStore.state.withLock { $0.sentImageFailure = nil }
        clock.advance(minutes: 10)
        await watch.refresh()
        file = try await submission()
        #expect(file.screenshots?.state == .capturing)
        #expect(file.screenshots?.sets.flatMap(\.shots).allSatisfy { $0.rejected == nil } == true)
        #expect(libraryWrites().filter { $0.hasPrefix("sendImage") }.count == 2)
    }

    @Test func givesUpEvenIfAppStoreConnectCannotBeRead() async throws {
        let (watch, _) = try await captureWithLibrary(sentState: "UPLOAD_COMPLETE")
        appStore.state.withLock { $0.libraryFailure = .unavailable("503") }
        // 打ち切る前は、読めなければやり直す
        clock.advance(minutes: 5)
        await watch.refresh()
        #expect(try await submission().screenshots?.state == .capturing)
        // 打ち切る時間を過ぎたら、読めなかった画像も打ち切って決着させる
        clock.advance(minutes: 3 * 60)
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured)
        #expect(shots.sets.flatMap(\.shots).contains { $0.rejected?.contains("3 時間") == true })
    }
}
