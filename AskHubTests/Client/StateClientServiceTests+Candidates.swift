@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 「対象に加える」の候補: 司令塔が書いた `repo-candidates.json` から、まだ対象でないものだけを出し、GitHub の owner/name の書き方で送る
extension StateClientServiceTests {
    private static func candidatesFile() -> [String: String] {
        [
            "repo-candidates.json": """
            {"v":1,"owners":[
              {"owner":"example","readAt":"2026-11-22T13:00:00Z","repositories":[
                {"name":"Memo-Widget-iOS","isPrivate":true,"description":"メモのウィジェット"},
                {"name":"sample-ios","isPrivate":false}
              ]},
              {"owner":"mrs1669","repositories":[],"problem":"mrs1669 の毎日のトークンで一覧を読めない（期限切れ・取り消し）"}
            ]}
            """
        ]
    }

    @Test
    func candidatesExcludeTargetsAndAreAddedWithGitHubName() async throws {
        let fixture = try makeService(files: Self.askingEpic(extra: Self.candidatesFile()))
        let service = fixture.service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        // 対象のリポジトリは候補に出さない
        #expect(snapshot.candidateRepositories.map(\.fullName) == ["example/Memo-Widget-iOS"])
        #expect(snapshot.candidateRepositories.first?.isPrivate == true)
        #expect(snapshot.candidateRepositories.first?.matches("ウィジェット") == true)
        #expect(snapshot.candidateProblems.map(\.owner) == ["mrs1669"])

        let id = "example/memo-widget-ios"
        try await service.perform(.addRepository(repositoryID: id))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        // 状態リポジトリのパスは大文字小文字を区別するので、GitHub の書き方で送る
        #expect(envelope.repo?.rawValue == "example/Memo-Widget-iOS")
        // 送った後は、司令塔が受け取る前から対象の一覧に出て、候補から外れる
        let added = try await service.fetchSnapshot()
        #expect(added.repositories.map(\.id).contains(id))
        #expect(added.candidateRepositories.isEmpty)
    }
}
