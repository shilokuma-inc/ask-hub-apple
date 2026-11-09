@testable import AskHub
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 押した時点で送った結果として当てること（送り終えていない・読み直していない・受け付けたのを読んだばかりの意図）と、受け付けの記録の軽い確かめ
extension StateClientServiceTests {
    private var answer: HumanIntent {
        .answer(epicID: Self.epicID, questionID: "Q1", optionID: "週ごと", note: "")
    }

    /// 送り終えていない意図は、書かずに、最後に読んだ状態に当てる（送った意図の一覧には入れない）。読む前は当てない
    @Test
    func overlaysUnsentIntentWithoutWriting() async throws {
        let fixture = try makeService()
        #expect(fixture.service.snapshot(overlaying: [answer]) == nil)
        _ = try await fixture.service.fetchSnapshot()

        let overlaid = try #require(fixture.service.snapshot(overlaying: [answer]))
        let question = try #require(overlaid.epic(Self.epicID)?.question("Q1"))
        guard case .answered(let response) = question.state else {
            Issue.record("送り終えていない回答が、答えた形で出ていない: \(question.state)")
            return
        }
        #expect(response.optionID == "週ごと")
        #expect(overlaid.sentIntents.isEmpty)
        #expect(try await sentEnvelopes(in: fixture).isEmpty)
        // 当てるのをやめれば元の形
        #expect(fixture.service.snapshot(overlaying: [])?.epic(Self.epicID)?.question("Q1")?.state == .open)
    }

    /// 送り終えた意図は、読み直す前から送った結果として出す
    @Test
    func sentIntentIsShownBeforeReread() async throws {
        let fixture = try makeService()
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(answer)

        let snapshot = try #require(fixture.service.snapshot(overlaying: []))
        guard case .answered? = snapshot.epic(Self.epicID)?.question("Q1")?.state else {
            Issue.record("送り終えて読み直す前の回答が、答えた形で出ていない")
            return
        }
        #expect(snapshot.sentIntents.isEmpty)
    }

    /// 受け付けの記録だけを読んで、司令塔が処理したかを確かめる
    @Test
    func hasReceiptReadsConsumedRecord() async throws {
        let fixture = try makeService()
        _ = try await fixture.service.fetchSnapshot()
        let receipt = try await fixture.service.perform(answer)
        let intentID = try #require(receipt.intentID)
        #expect(try await !fixture.service.hasReceipt(for: intentID))
        #expect(try await !fixture.service.hasReceipt(for: "not-a-nonce"))

        let nonce = try #require(ULID(rawValue: intentID))
        let consumed = #"{"v":1,"kind":"answer","consumedAt":"2027-01-15T08:00:00Z","result":"accepted"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: nonce), data: Data(consumed.utf8))
        #expect(try await fixture.service.hasReceipt(for: intentID))
    }

    /// 受け付けたのを読んだばかりの読み込みでは、状態が書き換わる前に読んだかもしれないので、送った結果を当て続ける。
    /// その後に始めた読み込みでは、当てるのをやめる（この見本では司令塔が状態を書き換えていないので、元の形に戻る）
    @Test
    func justAcceptedIntentStaysOverlaidForOneRead() async throws {
        let fixture = try makeService()
        _ = try await fixture.service.fetchSnapshot()
        let receipt = try await fixture.service.perform(answer)
        let waiting = try await fixture.service.fetchSnapshot()
        #expect(waiting.sentIntents.first?.state == .waiting)

        let nonce = try #require(receipt.intentID.flatMap(ULID.init(rawValue:)))
        let consumed = #"{"v":1,"kind":"answer","consumedAt":"2027-01-15T08:00:00Z","result":"accepted"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: nonce), data: Data(consumed.utf8))
        let accepted = try await fixture.service.fetchSnapshot()
        guard case .answered? = accepted.epic(Self.epicID)?.question("Q1")?.state else {
            Issue.record("受け付けたのを読んだばかりの回答が、答えた形のままになっていない")
            return
        }
        #expect(fixture.service.snapshot(overlaying: [])?.epic(Self.epicID)?.question("Q1")?.state != .open)

        let reread = try await fixture.service.fetchSnapshot()
        #expect(reread.epic(Self.epicID)?.question("Q1")?.state == .open)
    }
}
