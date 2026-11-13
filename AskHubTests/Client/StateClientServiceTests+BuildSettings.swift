@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// ビルドの設定: フォームで直した欄だけを元の JSON に書き戻し、司令塔と同じ決まりで確かめてから送る
extension StateClientServiceTests {
    private static let currentBuild = """
    {"baseBranch":"main","xcode":{"project":"Memo.xcodeproj","scheme":"Memo",
      "destinations":[{"platform":"iOS","deviceType":"iPhone 17 Pro","osVersion":"26.5"}],
      "testLight":{"onlyTesting":["MemoTests"]}},
     "childChecks":["build / build"],"finalChecks":["build / build","ui-test / ui-test"],"trustedReviewers":["coderabbitai[bot]"]}
    """

    @Test
    func buildSettingsDraftKeepsFieldsOutsideTheForm() throws {
        var draft = BuildSettingsDraft(json: Self.currentBuild)
        #expect(draft.scheme == "Memo")
        #expect(draft.baseBranch == "main")
        #expect(draft.destinations.map(\.osVersion) == ["26.5"])
        #expect(draft.finalChecks == "build / build\nui-test / ui-test")
        draft.scheme = "MemoApp"
        draft.childChecks = "build / build\n\nlint / lint "
        draft.destinations.append(.init(platform: "macOS"))
        let build = try StateIntentMapper.build(draft.text)
        #expect(build.xcode.scheme == "MemoApp")
        #expect(build.childChecks == ["build / build", "lint / lint"])
        #expect(build.xcode.destinations.last == .macOS)
        // フォームに出さない欄（テストの絞り込み）は残る
        #expect(build.xcode.testLight.onlyTesting == ["MemoTests"])
    }

    @Test
    func newBuildSettingsStartFromCommonShape() throws {
        var draft = BuildSettingsDraft(json: nil)
        #expect(draft.baseBranch == "develop")
        #expect(draft.childChecks == "build / build")
        draft.project = "App.xcodeproj"
        draft.scheme = "App"
        let build = try StateIntentMapper.build(draft.text)
        #expect(build.trustedReviewers.isEmpty)
        #expect(build.xcode.destinations.count == 1)
        // 司令塔と同じ決まりに合わないもの（チェックが空・JSON でない）は送らない
        draft.finalChecks = ""
        #expect(throws: ClientServiceError.self) { try StateIntentMapper.build(draft.text) }
        #expect(throws: ClientServiceError.self) { try StateIntentMapper.build("{") }
        #expect(!BuildSettingsDraft.isJSONObject("[]"))
    }

    @Test
    func configureRepositorySendsBuildAndShowsCurrentSettings() async throws {
        let repoFile = """
        {"v":1,"repo":"\(Self.repo)","platform":"apple","maxConcurrentEpics":1,"protection":{},"build":\(Self.currentBuild),
         "addedAt":"2026-11-01T00:00:00Z"}
        """
        let fixture = try makeService(files: Self.askingEpic(extra: ["repos/\(Self.repo)/repo.json": repoFile]))
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        let settings = try #require(snapshot.repository(Self.repo)?.build)
        #expect(settings.scheme == "Memo")
        #expect(settings.destinations == ["iPhone 17 Pro（iOS 26.5）"])
        #expect(settings.finalChecks == ["build / build", "ui-test / ui-test"])

        var draft = BuildSettingsDraft(json: settings.json)
        draft.scheme = "MemoApp"
        try await service.perform(.configureRepository(repositoryID: Self.repo, json: draft.text))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let configure = try ConfigureRepositoryIntent(envelope: envelope)
        #expect(configure.build.xcode.scheme == "MemoApp")
        #expect(configure.build.baseBranch == "main")
    }
}
