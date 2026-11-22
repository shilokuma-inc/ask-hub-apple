@testable import AskHub
import AskHubKit
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 依頼の添付: 中身を意図より先に置き、封筒に番号・名前・大きさ・ハッシュを書く
extension StateClientServiceTests {
    /// 依頼の添付は、意図より先に中身を置き、封筒には番号・名前・大きさ・ハッシュを書く。epic には添付の数を出す
    @Test
    func requestSendsAttachmentsBeforeIntent() async throws {
        let fixture = try makeService()
        let service = fixture.service, store = fixture.store, key = fixture.key
        _ = try await service.fetchSnapshot()
        let picked = [
            AttachmentFile(name: "案.md", type: "text/markdown", data: Data("# 案".utf8)),
            AttachmentFile(name: "mock.png", type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        ]
        let files = try RequestFile.make(picked).get()
        try await service.perform(.request(repositoryID: Self.repo, summary: "画面を直す", body: "添付の案で", attachments: files))

        let envelope = try await sentEnvelope(in: store, key: key)
        let request = try RequestIntent(envelope: envelope)
        #expect(request.attachments.map(\.name) == ["案.md", "mock.png"])
        #expect(request.attachments.map(\.number) == [1, 2])
        #expect(request.attachments[1].size == 4)
        for (offset, file) in picked.enumerated() {
            let path = StatePath.attachment(device: key.keyID, nonce: envelope.nonce, number: offset + 1)
            #expect(await store.data(at: path) == file.data)
        }
        let snapshot = try await service.fetchSnapshot()
        let epic = try #require(snapshot.epic(StateSnapshotBuilder.epicID(forRequest: envelope).rawValue))
        #expect(epic.request.attachmentCount == 2)
    }

    /// 「このリリースを直す」依頼は、直すリリースの版を封筒に書き、司令塔が受け取る前の epic にも出す。版の形が違えば送らない
    @Test
    func releaseFixRequestSendsVersion() async throws {
        let fixture = try makeService()
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        try await service.perform(.request(repositoryID: Self.repo, summary: "文言を直す", body: "審査で断られた", release: "1.4.0"))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(try RequestIntent(envelope: envelope).release == MarketingVersion(rawValue: "1.4.0"))
        let epic = try await service.fetchSnapshot().epic(StateSnapshotBuilder.epicID(forRequest: envelope).rawValue)
        #expect(epic?.release == "1.4.0")
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.request(repositoryID: Self.repo, summary: "直す", body: "", release: "v1.4"))
        }
    }

    /// 司令塔の決まりに合わない名前のファイルは、送る形にしない（司令塔に断られる依頼を送らない）
    @Test
    func requestFileRefusesNamesCommanderRejects() {
        let long = AttachmentFile(name: String(repeating: "あ", count: 201) + ".txt", type: "text/plain", data: Data("a".utf8))
        guard case .failure(let rejection) = RequestFile.make([long]) else {
            Issue.record("長すぎる名前のファイルを送る形にした")
            return
        }
        #expect(rejection.message.contains("名前が長すぎるか"))
        #expect((try? RequestFile.make([]).get())?.isEmpty == true)
    }
}
