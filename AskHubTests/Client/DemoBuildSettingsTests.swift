@testable import AskHub
import Foundation
import Testing

/// デモのビルドの設定も、状態リポジトリにつないだときと同じ形で出す（行き先の OS の版も出す）
@MainActor
struct DemoBuildSettingsTests {
    @Test
    func configureRepositoryShowsSettingsLikeState() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = DemoClientService(scenario: .standard, reactionDelay: 10, refreshInterval: .seconds(1)) { now }
        let repositoryID = DemoData.repositoryID("rain-ios")
        var draft = BuildSettingsDraft(json: nil)
        draft.project = "Rain.xcodeproj"
        draft.scheme = "Rain"
        draft.destinations = [.init(platform: "iOS", deviceType: "iPhone 17 Pro", osVersion: "26.5"), .init(platform: "macOS")]
        try await service.perform(.configureRepository(repositoryID: repositoryID, json: draft.text))
        let build = try #require(service.state.repository(repositoryID)?.build)
        #expect(build.scheme == "Rain")
        #expect(build.destinations == ["iPhone 17 Pro（iOS 26.5）", "Mac"])
        #expect(build.childChecks == ["build / build"])
    }
}
