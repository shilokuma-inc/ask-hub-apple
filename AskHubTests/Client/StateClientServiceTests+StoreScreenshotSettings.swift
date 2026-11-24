@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 撮影の設定の無いアプリのリリース: 始めるときに「撮らずに進む」を送れ、撮らなかったわけを出し、後から撮れる（#1306）
extension StateClientServiceTests {
    private var screenshotRepositoryID: TargetRepository.ID { Self.repo.lowercased() }

    /// 1.2.0 を撮らずに始めた（わけ付きの notConfigured）。`appKit` は、リポジトリが app-kit を呼んでいるとき
    static func skippedScreenshotFiles(appKit: Bool) -> [String: String] {
        let key = String(repeating: "k", count: 43)
        let installed = appKit ? #"{"ref":"\#(String(repeating: "a", count: 40))","version":"v1.2.0"}"# : "null"
        return releaseFiles(extra: [
            "repos/\(repo)/repo.json": """
            {"v":1,"repo":"\(repo)","platform":"apple","maxConcurrentEpics":1,"appKit":\(installed),
             "protection":{"appliedAt":null},"addedAt":"2026-11-01T00:00:00Z"}
            """,
            "repos/\(repo)/submissions/1.2.0.json": """
            {"v":1,"repo":"\(repo)","version":"1.2.0","origin":"askhub",
             "start":{"approval":{"keyId":"\(key)","nonce":"01JCN0NCE00000000000000009"},"at":"2027-01-20T01:00:00Z"},
             "screenshots":{"state":"notConfigured","startedAt":"2027-01-20T01:00:00Z","finishedAt":"2027-01-20T01:00:00Z",
                            "sets":[],"skipped":[],"failure":"リリースを始めるときに、撮らずに進むを選んだ"},
             "builds":[],"revision":0,"review":[],"createdAt":"2027-01-20T01:00:00Z","updatedAt":"2027-01-20T01:00:00Z"}
            """
        ])
    }

    @Test
    func sendsSkipScreenshotsOnlyWhenChosen() async throws {
        let fixture = try makeService(files: Self.releaseFiles())
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.startRelease(repositoryID: screenshotRepositoryID, version: "1.2.0", skipScreenshots: true))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.payload == ["version": .string("1.2.0"), "skipScreenshots": .bool(true)])
        #expect(try StartReleaseIntent(envelope: envelope).skipScreenshots)
    }

    /// 撮らなかったわけを出し、app-kit を呼ぶリポジトリなら後から撮れる（撮った組が無いので、選ばずにすべて撮る）
    @Test
    func showsWhyScreenshotsWereSkippedAndCapturesLater() async throws {
        let fixture = try makeService(files: Self.skippedScreenshotFiles(appKit: true))
        let snapshot = try await fixture.service.fetchSnapshot()
        let submission = try #require(snapshot.submission(Submission.id(screenshotRepositoryID, "1.2.0")))
        #expect(submission.screenshots?.state == .notConfigured("リリースを始めるときに、撮らずに進むを選んだ"))
        #expect(submission.screenshots?.sets.isEmpty == true && submission.canRetakeScreenshots)
        let capture = HumanIntent.retakeScreenshots(repositoryID: screenshotRepositoryID, version: "1.2.0", displayTypes: [], locales: [])
        #expect(fixture.service.supports(capture))
        try await fixture.service.perform(capture)
        let retake = try RetakeScreenshotsIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        #expect(retake.displayTypes.isEmpty && retake.locales.isEmpty)
    }

    /// 撮り方も app-kit も無いリポジトリでは、後から撮れない（司令塔も断る）
    @Test
    func refusesCapturingLaterWithoutSettingsOrAppKit() async throws {
        let fixture = try makeService(files: Self.skippedScreenshotFiles(appKit: false))
        let snapshot = try await fixture.service.fetchSnapshot()
        let submission = try #require(snapshot.submission(Submission.id(screenshotRepositoryID, "1.2.0")))
        #expect(!submission.canRetakeScreenshots)
        let capture = HumanIntent.retakeScreenshots(repositoryID: screenshotRepositoryID, version: "1.2.0", displayTypes: [], locales: [])
        #expect(!fixture.service.supports(capture))
        #expect(snapshot.repositories.first { $0.id == screenshotRepositoryID }?.build?.hasStoreScreenshots != true)
    }
}
