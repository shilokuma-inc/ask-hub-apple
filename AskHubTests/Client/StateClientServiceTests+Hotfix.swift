@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// hotfix: 配信中の版の次のパッチで始め、進行中のリリースは一時停止することを確かめてから送る
extension StateClientServiceTests {
    @Test
    func hotfixNeedsConfirmedSuspensionOfOpenRelease() async throws {
        // 1.1.0 を配信し、1.2.0 のリリースが進行中
        let fixture = try makeService(files: Self.submissionFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        let repositoryID = Self.repo.lowercased()
        #expect(snapshot.hotfixVersion(of: repositoryID, from: "1.1.0") == "1.1.1")
        #expect(snapshot.openRelease(of: repositoryID)?.version == "1.2.0")
        // 次のパッチでない・一時停止を確かめていない hotfix は送れない
        #expect(!fixture.service.supports(.startHotfix(repositoryID: repositoryID, version: "1.1.2", suspend: "1.2.0")))
        #expect(!fixture.service.supports(.startHotfix(repositoryID: repositoryID, version: "1.1.1", suspend: nil)))
        let intent = HumanIntent.startHotfix(repositoryID: repositoryID, version: "1.1.1", suspend: "1.2.0")
        #expect(fixture.service.supports(intent))
        try await fixture.service.perform(intent)
        let start = try StartReleaseIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        #expect(start.version.rawValue == "1.1.1" && start.hotfix && start.suspend?.rawValue == "1.2.0")
    }
}
