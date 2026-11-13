@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 対象から外す: 外したリポジトリは一覧から外して「外したリポジトリ」に出し、加え直すときは元の owner/name の書き方で送る。
/// 終わっていない epic のあるリポジトリは外せない
extension StateClientServiceTests {
    /// 大文字を含む名前の、外したリポジトリ
    private static let removedRepo = "Example/Old-Memo-iOS"

    private static func removedRepositoryFile() -> [String: String] {
        [
            "repos/\(removedRepo)/repo.json": """
            {"v":1,"repo":"\(removedRepo)","platform":"apple","maxConcurrentEpics":1,"protection":{},
             "addedAt":"2026-10-01T00:00:00Z","removedAt":"2026-11-10T00:00:00Z"}
            """
        ]
    }

    @Test
    func removedRepositoryIsListedSeparatelyAndAddedBackWithItsName() async throws {
        let fixture = try makeService(files: Self.askingEpic(extra: Self.removedRepositoryFile()))
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        let id = Self.removedRepo.lowercased()
        #expect(snapshot.repositories.map(\.id) == [Self.repo])
        #expect(snapshot.removedRepositories.map(\.id) == [id])
        #expect(snapshot.isRemoved(id))
        // 外す前の epic の名前とアイコンのため、引き当ては外したリポジトリも返す
        #expect(snapshot.repository(id)?.fullName == Self.removedRepo)
        #expect(!service.supports(.removeRepository(repositoryID: id)))
        // 外したリポジトリには依頼を送らない（司令塔も断る）
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.request(repositoryID: id, summary: "s", body: ""))
        }

        try await service.perform(.addRepository(repositoryID: id))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        // 状態リポジトリのパスは大文字小文字を区別するので、外す前の書き方で送る
        #expect(envelope.kind == AddRepositoryIntent.kind)
        #expect(envelope.repo?.rawValue == Self.removedRepo)
        let restored = try await service.fetchSnapshot()
        #expect(restored.repositories.map(\.id).contains(id))
        #expect(restored.removedRepositories.isEmpty)
    }

    @Test
    func repositoryWithoutActiveEpicsCanBeRemoved() async throws {
        // 依頼先にした epic をマージした後のリポジトリ（実機確認の材料と同じ）
        let files = Self.askingEpic(extra: [
            "repos/\(Self.repo)/epics/\(Self.epicID)/epic.json": """
            {"v":1,"id":"\(Self.epicID)","repo":"\(Self.repo)","title":"ランキング","summary":"ランキング","discussion":5,"stage":"merged",
             "mac":"mac-mini","branch":null,"finalPullRequest":512,"goalVersion":null,"origin":null,
             "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T01:00:00Z"}
            """
        ])
        let fixture = try makeService(files: files)
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let remove = HumanIntent.removeRepository(repositoryID: Self.repo)
        #expect(service.supports(remove))
        try await service.perform(remove)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(try RemoveRepositoryIntent(envelope: envelope).repo.rawValue == Self.repo)
        // 司令塔が受け取る前から、外した形で出す
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.repositories.isEmpty)
        #expect(snapshot.removedRepositories.map(\.id) == [Self.repo])
        #expect(snapshot.epic(Self.epicID) != nil)
    }

    @Test
    func repositoryWithActiveEpicCannotBeRemoved() async throws {
        let fixture = try makeService()
        _ = try await fixture.service.fetchSnapshot()
        let remove = HumanIntent.removeRepository(repositoryID: Self.repo)
        #expect(!fixture.service.supports(remove))
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(remove)
        }
        #expect(try await sentEnvelopes(in: fixture).isEmpty)
    }
}
