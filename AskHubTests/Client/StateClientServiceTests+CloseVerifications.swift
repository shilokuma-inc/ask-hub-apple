@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 実機確認のまとめての答え: 「まとめて確認した」「確かめずに閉じる」は、epic とゴールの版に結びつけた 1 つの意図（`closeVerifications`）で送る
extension StateClientServiceTests {
    private static let closingBase = "repos/\(repo)/epics/\(epicID)"

    /// 司令塔が受け取る前から、まだ答えていない項目をその答えとして出す（記録された答えは変えない）。
    /// 答えていない項目が無くなったら、まとめての答えも送れない。送った意図には呼び名と反映を待つ対象を付ける
    @Test
    func closeVerificationsSendsOneIntentAndOverlaysRemaining() async throws {
        let answers = """
        {"v":1,"answers":[{"id":"v2","result":"problem","note":"線が見えない",
          "intent":{"keyId":"\(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000001"},"at":"2027-01-15T07:50:00Z"}]}
        """
        let fixture = try makeService(files: Self.mergedEpic(extra: ["\(Self.closingBase)/verifications.json": answers]))
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let close = HumanIntent.closeVerifications(epicID: Self.epicID, reply: .skipped(note: " 次の版で見る "))
        #expect(service.supports(close))

        try await service.perform(close)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let intent = try CloseVerificationsIntent(envelope: envelope)
        #expect(intent.target.epic.rawValue == Self.epicID)
        #expect(intent.target.version == 1)
        #expect(intent.result == .skipped)
        #expect(intent.note == "次の版で見る")

        let snapshot = try await service.fetchSnapshot()
        let states = snapshot.epic(Self.epicID)?.finalReview?.verifications.map(\.state)
        #expect(states == [.skipped(note: "次の版で見る"), .problem(note: "線が見えない")])
        #expect(!service.supports(close))
        #expect(!service.supports(.closeVerifications(epicID: Self.epicID, reply: .confirmed)))
        let sent = try #require(snapshot.sentIntents.first)
        #expect(sent.title == "確かめずに閉じる · ランキング")
        #expect(sent.target == .verifications(epicID: Self.epicID))
    }

    /// まとめて確認したは理由を持たない。先に 1 項目ずつ送った答えは、その答えのまま残す
    @Test
    func closeVerificationsConfirmedKeepsEarlierPendingAnswer() async throws {
        let fixture = try makeService(files: Self.mergedEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        try await service.perform(.verify(epicID: Self.epicID, itemID: "v1", reply: .confirmed))
        try await service.perform(.closeVerifications(epicID: Self.epicID, reply: .confirmed))

        let kinds = try await sentEnvelopes(in: fixture).map(\.kind)
        #expect(kinds.sorted() == [CloseVerificationsIntent.kind, VerifyIntent.kind].sorted())
        let close = try #require(try await sentEnvelopes(in: fixture).first { $0.kind == CloseVerificationsIntent.kind })
        #expect(close.payload == ["result": .string("confirmed")])
        let states = try await service.fetchSnapshot().epic(Self.epicID)?.finalReview?.verifications.map(\.state)
        #expect(states == [.confirmed, .confirmed])
    }

    /// マージする前の epic には送れない。理由が長すぎれば送らない
    @Test
    func closeVerificationsRejectsUnmergedEpicAndLongNote() async throws {
        let reviewing = try makeService(files: Self.mergedEpic(stage: "reviewing")).service
        _ = try await reviewing.fetchSnapshot()
        #expect(!reviewing.supports(.closeVerifications(epicID: Self.epicID, reply: .confirmed)))

        let fixture = try makeService(files: Self.mergedEpic())
        _ = try await fixture.service.fetchSnapshot()
        let long = String(repeating: "あ", count: CloseVerificationsIntent.maximumNoteLength + 1)
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.closeVerifications(epicID: Self.epicID, reply: .skipped(note: long)))
        }
        #expect(try await sentEnvelopes(in: fixture).isEmpty)
    }
}
