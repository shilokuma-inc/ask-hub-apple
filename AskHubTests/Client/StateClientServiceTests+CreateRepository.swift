@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// テンプレートから新しいアプリを作る: 送ると、司令塔が作る前から選んだアプリ名で対象の一覧に出る。対象と同じ名前・決まりに合わない名前は送らない
extension StateClientServiceTests {
    private static func newApp(name: String = "Memo-Widget-iOS", appName: String = "MemoWidget") -> NewAppRequest {
        NewAppRequest(
            template: .visionos,
            owner: "example",
            name: name,
            appName: appName,
            bundleId: "jp.shilokuma.MemoWidget",
            visibility: .private
        )
    }

    @Test
    func createRepositorySendsTemplateAndShowsRepositoryBeforeCommanderCreatesIt() async throws {
        let fixture = try makeService()
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let request = Self.newApp()
        #expect(service.supports(.createRepository(request)))
        try await service.perform(.createRepository(request))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let create = try CreateRepositoryIntent(envelope: envelope)
        // 状態リポジトリのパスは大文字小文字を区別するので、入れた書き方のまま送る
        #expect(create.repo.rawValue == "example/Memo-Widget-iOS")
        #expect(create.template == .visionos)
        #expect(create.visibility == .private)
        #expect(create.appName == "MemoWidget")
        #expect(create.bundleId == "jp.shilokuma.MemoWidget")
        let snapshot = try await service.fetchSnapshot()
        let created = try #require(snapshot.repository(request.repositoryID))
        #expect(created.appName == "MemoWidget")
        #expect(snapshot.sentIntents.first?.title == "新しいアプリ（example/Memo-Widget-iOS）")
    }

    @Test
    func createRepositoryRefusesTargetNameAndBadNames() async throws {
        let fixture = try makeService()
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        // 対象のリポジトリと同じ名前
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.createRepository(Self.newApp(name: "sample-ios")))
        }
        // アプリ名は英字で始まる英数字
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.createRepository(Self.newApp(appName: "memo-widget")))
        }
    }

    @Test(arguments: [
        ("kobuta-quiz-ios", "KobutaQuiz"),
        ("planetarium-visionos", "Planetarium"),
        ("askhub-create-check", "AskhubCreateCheck"),
        ("2048-game-ios", "2048Game"),
        ("ios", "Ios"),
        ("メモ", "")
    ])
    func suggestsAppNameFromRepositoryName(_ name: String, _ expected: String) {
        let suggested = NewAppRequest.suggestedAppName(from: name)
        // 数字で始まる名前は、英字で始まるところから使う
        #expect(suggested == (expected.first?.isNumber == true ? String(expected.drop { !$0.isLetter }) : expected))
    }
}
