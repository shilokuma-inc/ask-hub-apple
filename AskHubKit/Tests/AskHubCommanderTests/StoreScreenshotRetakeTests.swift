@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import CoreGraphics
import Foundation
import Testing

/// 人が頼んだスクショの撮り直し（`retakeScreenshots`）
extension ReleaseWatchTests {
    static let retakeIntent = IntentReference(keyId: AppStoreSetupTests.keyID, nonce: ULID(rawValue: "01JCN0NCE00000000000000008")!)
    static let retakeHead = String(repeating: "e", count: 40)

    /// 撮影の記録に撮り直しの頼みを書く（受け付けた後の形）
    func requestRetake(displayTypes: [String] = [], locales: [String] = []) async throws {
        var file = try await submission()
        let at = Timestamp(clock.now)
        file.screenshots?.retake = .init(displayTypes: displayTypes, locales: locales, approval: Self.retakeIntent, at: at)
        try await putSubmission(file)
    }

    /// 次の撮影の実行（id 102・release ブランチの新しい先頭）を用意する
    func prepareSecondRun() {
        hosting.workflows.withLock { state in
            state.dispatchReply = .success(DispatchedRun(id: 44_900_000_102, url: nil))
            state.runs[44_900_000_102] = screenshotRun(id: 44_900_000_102, status: "completed", conclusion: "success", sha: Self.retakeHead)
            state.artifacts[44_900_000_102] = state.artifacts[Self.screenshotRun]
        }
    }

    @Test func retakesEveryScreenOnTheReleaseBranch() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]])
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)
        #expect(try await submission().screenshots?.state == .captured)

        try await requestRetake()
        // 頼みを受け付けてから撮り直しを始めるまでは、審査に出す準備をそろえない
        #expect(try await submission().screenshots?.awaitsRetake == true)
        #expect(try await !submission().isPrepared)
        prepareSecondRun()
        clock.advance(minutes: 1)
        await watch.refresh()
        var shots = try #require(try await submission().screenshots)
        #expect(shots.state == .capturing && shots.retake?.startedAt != nil && shots.run?.id == 44_900_000_102)
        #expect(hosting.workflows.withLock { $0.dispatches.last?.inputs["display_types"] } == "APP_IPHONE_67,APP_IPHONE_DUO")

        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        await watch.waitForRefresh()
        shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.commit == Self.retakeHead)
    }

    @Test func retakesOnlyTheChosenScreensAndKeepsTheRest() async throws {
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
        let before = try #require(try await submission().screenshots)
        let japanese = try #require(before.sets.first { $0.displayType == Self.iPhone && $0.locale == "ja" })

        // iPhone Duo の日本語だけを撮り直す
        try await requestRetake(displayTypes: [Self.duo], locales: ["ja"])
        prepareSecondRun()
        clock.advance(minutes: 1)
        await watch.refresh()
        let dispatched = try #require(hosting.workflows.withLock { $0.dispatches.last })
        #expect(dispatched.inputs["display_types"] == "APP_IPHONE_DUO" && dispatched.inputs["languages"] == "ja")
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()
        await watch.waitForRefresh()

        let after = try #require(try await submission().screenshots)
        #expect(after.state == .captured && after.commit == Self.retakeHead)
        // 撮り直さなかった組（iPhone 6.9 の日本語と英語、Duo の英語）は前の結果を引き継ぐ
        #expect(after.sets.first { $0.displayType == Self.iPhone && $0.locale == "ja" } == japanese)
        #expect(Set(after.sets.map { "\($0.displayType)/\($0.locale)" }) == Set(before.sets.map { "\($0.displayType)/\($0.locale)" }))
        // 引き継いだ組の差のある画面の元の画像を、新しい撮影の置き場所に写した（審査に出すときに上げる）
        let copied = StoreScreenshotRun.original(
            in: capturer.originals(Self.repo, version: Self.next, commit: Self.retakeHead), target: Self.japanese, index: 2
        )
        #expect(try Data(contentsOf: copied) == Self.newDetail)
    }

    @Test func cancelsTheRunningCaptureWhenRetaking() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        let watch = watch(screenshots: FakeStoreScreenshots())
        await watch.refresh()
        hosting.workflows.withLock { $0.runs[Self.screenshotRun] = screenshotRun(status: "in_progress") }
        try await requestRetake()
        prepareSecondRun()
        clock.advance(minutes: 1)
        await watch.refresh()
        #expect(hosting.workflows.withLock { $0.cancelledRuns } == [Self.screenshotRun])
        #expect(try await submission().screenshots?.run?.id == 44_900_000_102)
    }

    @Test func refusesToRetakeAfterSubmittingOrWhileTheUITestCaptures() throws {
        let now = Timestamp(Self.now)
        var file = SubmissionFile(repo: Self.repo, version: Self.next, origin: .askhub, createdAt: now, updatedAt: now)
        #expect(RetakeScreenshotsHandler.problem(retaking: file, canCapture: true)?.contains("撮り始めていない") == true)
        file.screenshots = .init(state: .capturing, startedAt: now)
        #expect(RetakeScreenshotsHandler.problem(retaking: file, canCapture: true)?.contains("UI テスト") == true)
        file.screenshots = .init(state: .captured, startedAt: now)
        #expect(RetakeScreenshotsHandler.problem(retaking: file, canCapture: true) == nil)
        file.screenshots?.retake = .init(approval: Self.retakeIntent, at: now)
        #expect(RetakeScreenshotsHandler.problem(retaking: file, canCapture: true)?.contains("もう頼んでいる") == true)
        file.screenshots?.retake = nil
        file.submit = .init(approval: Self.retakeIntent, at: now, builds: [], whatsNew: [], releaseType: .afterApproval)
        #expect(RetakeScreenshotsHandler.problem(retaking: file, canCapture: true)?.contains("審査に出した後") == true)
    }

    /// 撮らなかった版（`notConfigured`）は、リポジトリで撮れる（撮影の設定がある）ときだけ後から撮れる
    @Test func acceptsCapturingLaterOnlyWhenTheRepositoryCanCapture() {
        let now = Timestamp(Self.now)
        var file = SubmissionFile(repo: Self.repo, version: Self.next, origin: .askhub, createdAt: now, updatedAt: now)
        file.screenshots = .init(state: .notConfigured, startedAt: now, finishedAt: now)
        #expect(RetakeScreenshotsHandler.problem(retaking: file, canCapture: false)?.contains("撮り方の設定") == true)
        #expect(RetakeScreenshotsHandler.problem(retaking: file, canCapture: true) == nil)
    }

    /// 撮影の設定が無いまま始めた版も、設定を足した後に頼めば、今の release ブランチの先頭で撮る
    @Test func capturesLaterAReleaseStartedWithoutScreenshotSettings() async throws {
        try await startRelease()
        let watch = watch(screenshots: FakeStoreScreenshots())
        await watch.refresh()
        #expect(try await submission().screenshots?.state == .notConfigured)

        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]])
        try await requestRetake()
        clock.advance(minutes: 1)
        await captureOnActions(watch)
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.failure == nil && shots.run?.id == Self.screenshotRun)
        #expect(shots.sets.map(\.locale).sorted() == ["en-US", "ja"])
        #expect(hosting.workflows.withLock { $0.dispatches.count } == 1)
    }
}
