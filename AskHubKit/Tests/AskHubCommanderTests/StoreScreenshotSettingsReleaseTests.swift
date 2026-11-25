@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 撮り方の設定の無いアプリのリリースで、司令塔が撮り方を作ってから撮る（#1304）
extension ReleaseWatchTests {
    /// app-kit を呼び、撮影のワークフローと `AppStore/` のファイルを持つ（template の形。日本語と英語）
    func useAppKitScreenshots(languages: String? = StoreScreenshotSettingsBuilderTests.template) {
        hosting.state.withLock { state in
            state.observed = AppKitObserved(
                files: [:],
                config: nil,
                callerRef: AppKitRolloutTests.new.ref,
                callerKitRef: AppKitRolloutTests.new.ref,
                screenshotSources: .init(screenshots: StoreScreenshotSettingsBuilderTests.screenshots, languages: languages)
            )
        }
        appStore.state.withLock { $0.placementGroups = StoreScreenshotSettingsBuilderTests.groups }
    }

    static var madeSettings: StoreScreenshotWorkflow {
        var made = StoreScreenshotSettingsBuilderTests.built
        made.languages = ["ja": .init(language: "ja"), "en-US": .init(language: "en")]
        return made
    }

    /// 撮り方が無くても、app-kit の撮影を使うなら、base のファイルから撮り方を作って書き、そのまま撮る
    @Test func configuresScreenshotSettingsAndCapturesWhenTheReleaseStarts() async throws {
        try await startRelease()
        useAppKitScreenshots()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]])
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)
        #expect(try await repositoryFile().build?.storeScreenshots == .actions(Self.madeSettings))
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.failure == nil)
        let inputs = try #require(hosting.workflows.withLock { $0.dispatches.first?.inputs })
        #expect(inputs["display_types"] == "APP_IPAD_PRO_3GEN_129,APP_IPHONE_61,APP_IPHONE_67,APP_IPHONE_DUO")
        // artifact の無い表示サイズ（iPad・6.3 inch・iPhone Duo）は、撮らなかったわけを出す
        #expect(Set(shots.skipped.map(\.displayType)) == ["IPAD_13_PROFILE", "IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE", Self.duo])
    }

    /// 読んだ後に人がビルドの設定（base）を替えていたら、古い base のファイルから作った撮り方は書かず、次の見回りで作り直す
    @Test func rebuildsSettingsWhenTheBuildChangedWhileReading() async throws {
        try await startRelease()
        useAppKitScreenshots()
        let store = store
        hosting.observing.withLock { hook in
            hook = {
                guard let data = await store.data(at: StatePath.repository(Self.repo)),
                      var file = try? StateFileCoder.decode(RepositoryFile.self, from: data) else { return }
                file.build?.baseBranch = "main"
                if let encoded = try? StateFileCoder.encode(file) { await store.put(StatePath.repository(Self.repo), data: encoded) }
            }
        }
        let watch = watch(screenshots: FakeStoreScreenshots())
        await watch.refresh()
        #expect(try await repositoryFile().build?.storeScreenshots == nil)
        #expect(try await repositoryFile().build?.baseBranch == "main")
        #expect(hosting.workflows.withLock { $0.dispatches.isEmpty })
        #expect(try await submission().screenshots == nil)

        hosting.observing.withLock { $0 = nil }
        clock.advance(minutes: 1)
        await watch.refresh()
        #expect(try await repositoryFile().build?.storeScreenshots == .actions(Self.madeSettings))
        #expect(hosting.workflows.withLock { $0.dispatches.count } == 1)
    }

    /// app-kit の撮影を使わないアプリは撮らず、わけを書く。使うのに作れなければ、わけを書いて撮れなかったことにする
    @Test func explainsWhyNoScreenshotsWereCapturedWithoutSettings() async throws {
        try await startRelease()
        let watch = watch(screenshots: FakeStoreScreenshots())
        await watch.refresh()
        var shots = try #require(try await submission().screenshots)
        #expect(shots.state == .notConfigured && shots.failure == ReleaseWatch.screenshotWorkflowUnused)

        try await putSubmission(SubmissionHandlersTests.started())
        useAppKitScreenshots(languages: nil)
        clock.advance(minutes: 1)
        await watch.refresh()
        shots = try #require(try await submission().screenshots)
        #expect(shots.state == .failed && shots.failure == "作れない（AppStore/languages.json が無い・読めない）。直してから、スクショを撮る")
        #expect(try await repositoryFile().build?.storeScreenshots == nil)
        #expect(hosting.workflows.withLock { $0.dispatches.isEmpty })
    }

    /// 撮らずに始めた版も、app-kit のあるリポジトリなら、後から頼めば撮り方を作って撮る
    @Test func capturesLaterAfterConfiguringSettingsOfAnAppKitRepository() async throws {
        try await startRelease()
        let watch = watch(screenshots: FakeStoreScreenshots())
        await watch.refresh()
        #expect(try await submission().screenshots?.state == .notConfigured)

        // 後から app-kit に入れ替え、ずれの点検が呼んでいる版を書いた
        var repository = try await repositoryFile()
        repository.appKit = RepositoryFile.AppKit(ref: AppKitRolloutTests.new.ref, version: AppKitRolloutTests.new.version)
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(repository))
        #expect(repository.canCaptureStoreScreenshots)
        #expect(try await submission().retakeProblem(canCapture: true) == nil)
        useAppKitScreenshots()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]])
        try await requestRetake()
        clock.advance(minutes: 1)
        await captureOnActions(watch)
        #expect(try await submission().screenshots?.state == .captured)
        #expect(try await repositoryFile().build?.storeScreenshots == .actions(Self.madeSettings))
    }

    /// 撮り方の配置グループがリファレンスデータに無ければ、その組は取り込まずにわけを出す（審査に出すときに黙って落ちないように）
    @Test func skipsPlacementGroupsMissingFromTheReferenceData() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        liveScreenshots([Self.home], localization: "l-ja", locale: "ja")
        liveScreenshots([Self.home], localization: "l-en", locale: "en-US")
        screenshotArtifacts(iPhone: ["ja": [Self.home], "en": [Self.home]], duo: ["ja": [Self.home], "en": [Self.home]])
        appStore.state.withLock { $0.placementGroups = StoreScreenshotSettingsBuilderTests.groups.filter { $0.id != Self.duo } }
        let watch = watch(screenshots: FakeStoreScreenshots())
        await captureOnActions(watch)
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .captured && shots.sets.allSatisfy { $0.displayType == Self.iPhone })
        #expect(shots.skipped.contains(.init(displayType: Self.duo, reason: WorkflowScreenshotImport.unknownPlacementReason(Self.duo))))
    }
}
