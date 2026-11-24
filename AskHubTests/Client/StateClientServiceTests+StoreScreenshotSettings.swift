@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 撮影の設定の無いアプリのリリース: 始めるときに「撮らずに進む」を送れる（#1306）
extension StateClientServiceTests {
    private var screenshotRepositoryID: TargetRepository.ID { Self.repo.lowercased() }

    @Test
    func sendsSkipScreenshotsOnlyWhenChosen() async throws {
        let fixture = try makeService(files: Self.releaseFiles())
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.startRelease(repositoryID: screenshotRepositoryID, version: "1.2.0", skipScreenshots: true))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.payload == ["version": .string("1.2.0"), "skipScreenshots": .bool(true)])
        #expect(try StartReleaseIntent(envelope: envelope).skipScreenshots)
    }
}
