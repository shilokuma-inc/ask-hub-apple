@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 人に渡されたタスクのジョブを飛ばす: 理由とメモを試行の番号つきで送ること、処理を待つ間と司令塔が飛ばした後の出し方
extension StateClientServiceTests {
    /// 飛ばすと、理由と前後の空白を除いたメモを送る。司令塔が受け取るまでも、タスクを飛ばしたものとして出し、「対処が要ります」を外す
    @Test
    func skippingWaitingTaskSendsReasonAndShowsSkipped() async throws {
        let fixture = try makeService(files: Self.waitingImplementationEpic())
        let blocker = try #require(try await fixture.service.fetchSnapshot().epic(Self.epicID)?.blocker)
        let skip = HumanIntent.skipTask(epicID: Self.epicID, reason: .handledElsewhere, note: " Android で直す\n", target: blocker.target)
        #expect(fixture.service.supports(skip))

        try await fixture.service.perform(skip)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == SkipTaskIntent.kind)
        #expect(envelope.targetVersion == "1")
        #expect(envelope.payload == ["reason": .string("handledElsewhere"), "note": .string("Android で直す")])
        let epic = try #require(try await fixture.service.fetchSnapshot().epic(Self.epicID))
        #expect(epic.blocker == nil)
        #expect(epic.tasks[1].state == .skipped(reason: "人が別にやる・Android で直す"))
        #expect(epic.history.last?.text == "タスク 2「一覧に出す」を飛ばしました。司令塔が受け取るのを待っています")
    }

    /// 送るまでに「対処が要ります」のジョブが替わっていたら送らない。長すぎるメモも送らない
    @Test
    func skippingIsNotSentForStaleTargetOrLongNote() async throws {
        let fixture = try makeService(files: Self.waitingImplementationEpic())
        let blocker = try #require(try await fixture.service.fetchSnapshot().epic(Self.epicID)?.blocker)
        let stale = HumanIntent.skipTask(epicID: Self.epicID, reason: .notNeeded, note: "", target: "01JCJ0B0000000000000000999/1")
        await #expect(throws: ClientServiceError.self) { try await fixture.service.perform(stale) }
        let note = String(repeating: "あ", count: SkipTaskIntent.maximumNoteLength + 1)
        let long = HumanIntent.skipTask(epicID: Self.epicID, reason: .notNeeded, note: note, target: blocker.target)
        await #expect(throws: ClientServiceError.self) { try await fixture.service.perform(long) }
        #expect(try await fixture.store.list("intents")?.isEmpty ?? true)
    }

    /// 司令塔が飛ばしたタスクは、理由（メモがあれば添える）を付けて「飛ばした」と出す
    @Test
    func skippedTaskIsShownWithReason() async throws {
        var files = Self.waitingImplementationEpic()
        let intent = #"{"keyId":"\#(String(repeating: "k", count: 43))","nonce":"01JCN0NCE00000000000000009"}"#
        let skip = #"{"reason":"notNeeded","note":"今回は要らない","intent":\#(intent),"at":"2027-01-15T07:40:00Z"}"#
        files["repos/\(Self.repo)/epics/\(Self.epicID)/goal.json"] = """
        {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
         "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"done"},
                  {"id":"t2","title":"一覧に出す","dependsOn":[],"state":"skipped","skip":\(skip)},
                  {"id":"t3","title":"通知する","dependsOn":[],"state":"pending"}],"humanTasks":[]}
        """
        let epic = try #require(try await makeService(files: files).service.fetchSnapshot().epic(Self.epicID))
        #expect(epic.tasks[1].state == .skipped(reason: "やらない・今回は要らない"))
    }
}
