@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 開始した epic の一時停止・再開・ほかの Mac への引き継ぎ: 送る形と、送れるとき・一時停止中の出し方・オフラインで止まったジョブとの区別
extension StateClientServiceTests {
    private static let pauseBase = "repos/\(repo)/epics/\(epicID)"
    private static let reviewingJobID = "01JCJ0B0000000000000000201"
    private static let waitingJobID = "01JCJ0B0000000000000000202"

    private static func runningEpicFile(pause: String = "null") -> String {
        """
        {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"ランキング","summary":"ランキングの表示を変える","discussion":5,"stage":"running",
         "mac":"mac-mini","branch":"askhub/\(epicID)","finalPullRequest":null,"goalVersion":1,"origin":null,"pause":\(pause),
         "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2027-01-15T07:00:00Z"}
        """
    }

    private static func pauseJob(_ id: String, kind: String, state: String, attempts: Int) -> String {
        """
        {"v":1,"id":"\(id)","kind":"\(kind)","repo":"\(repo)","epic":"\(epicID)","task":"t1","assignedMac":"mac-mini",
         "needs":{"claude":true,"build":true},"dependsOn":[],"state":"\(state)","attempts":\(attempts),"nextRunAt":null,
         "input":{},"origin":null,
         "createdAt":"2027-01-15T07:00:00Z","updatedAt":"2027-01-15T07:10:00Z"}
        """
    }

    private static func runningAttempt(_ job: String, heartbeatAt: String) -> String {
        """
        {"v":1,"job":"\(job)","n":1,"mac":"mac-mini","startedAt":"2027-01-15T05:00:00Z","heartbeatAt":"2027-01-15T\(heartbeatAt):00Z",
         "endedAt":null,"outcome":"running","failure":null}
        """
    }

    /// 実装している epic。`reviewing` は子 PR のレビューのジョブの状態（実行中の試行を持つ）、`waiting` は次の実装のジョブの状態
    private static func pausableEpic(
        pause: String = "null",
        reviewing: String = "running",
        waiting: String = "assigned"
    ) -> [String: String] {
        askingEpic(stage: "running", extra: [
            "\(pauseBase)/epic.json": runningEpicFile(pause: pause),
            "\(pauseBase)/goal.json": """
            {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
             "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"running"}],"humanTasks":[]}
            """,
            "\(pauseBase)/jobs/\(reviewingJobID).json": pauseJob(reviewingJobID, kind: "reviewTask", state: reviewing, attempts: 1),
            "\(pauseBase)/attempts/\(reviewingJobID)/1.json": runningAttempt(reviewingJobID, heartbeatAt: "07:56"),
            "\(pauseBase)/jobs/\(waitingJobID).json": pauseJob(waitingJobID, kind: "implementTask", state: waiting, attempts: 0)
        ])
    }

    /// 一時停止は epic を対象に版なしで送り、司令塔が受け取るまでも一時停止中として出す。止めている間は再開と引き継ぎを送れる
    @Test
    func pauseIsSentAndShownUntilResumed() async throws {
        let fixture = try makeService(files: Self.pausableEpic())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        #expect(service.supports(.pause(epicID: Self.epicID)))
        #expect(!service.supports(.resume(epicID: Self.epicID)))
        // 一時停止していない epic は、Mac でジョブが動いている間は引き継げない
        #expect(!service.supports(.handOver(epicID: Self.epicID, macID: "")))
        await #expect(throws: ClientServiceError(message: "Mac で動いている作業があります。一時停止してから引き継いでください")) {
            try await service.perform(.handOver(epicID: Self.epicID, macID: "macbook-b"))
        }

        try await service.perform(.pause(epicID: Self.epicID))
        let pause = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(pause.kind == PauseEpicIntent.kind)
        #expect(pause.target == IntentEnvelope.Target(type: "epic", epic: ULID(rawValue: Self.epicID)))
        #expect(pause.targetVersion == nil)
        #expect(pause.payload?.isEmpty ?? true)

        let waitingSnapshot = try await service.fetchSnapshot()
        #expect(waitingSnapshot.sourceFailures.isEmpty)
        let waiting = try #require(waitingSnapshot.epic(Self.epicID))
        #expect(waiting.isPaused)
        #expect(waiting.history.last?.text == "一時停止しました。司令塔が受け取るのを待っています")
        #expect(waitingSnapshot.sentIntents.first?.title == "一時停止 · ランキング")
        #expect(!service.supports(.pause(epicID: Self.epicID)))
        #expect(service.supports(.resume(epicID: Self.epicID)))
        #expect(service.supports(.handOver(epicID: Self.epicID, macID: "")))

        // 司令塔が受け付け、まだ動いていないジョブを止めた。動いているレビューは最後まで続く
        let consumed = #"{"v":1,"kind":"pauseEpic","consumedAt":"2027-01-15T07:58:00Z","result":"accepted"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: pause.nonce), data: Data(consumed.utf8))
        let origin = #"{"keyId":"\#(fixture.key.keyID.rawValue)","nonce":"\#(pause.nonce.rawValue)"}"#
        let mark = #"{"since":"2027-01-15T07:58:00Z","origin":\#(origin)}"#
        await fixture.store.put("\(Self.pauseBase)/epic.json", data: Data(Self.runningEpicFile(pause: mark).utf8))
        let held = Self.pauseJob(Self.waitingJobID, kind: "implementTask", state: "paused", attempts: 0)
        await fixture.store.put("\(Self.pauseBase)/jobs/\(Self.waitingJobID).json", data: Data(held.utf8))
        let pausedSnapshot = try await service.fetchSnapshot()
        #expect(pausedSnapshot.sourceFailures.isEmpty)
        let paused = try #require(pausedSnapshot.epic(Self.epicID))
        #expect(paused.pausedAt == ISO8601DateFormatter().date(from: "2027-01-15T07:58:00Z"))
        #expect(paused.history.contains { $0.text == "一時停止しました" })
        // 止めたジョブは「オフライン」とは出さず、動いているレビューだけを出す
        #expect(paused.activities.count == 1)
        #expect(paused.activities.allSatisfy { if case .step(_, .running) = $0.kind { true } else { false } })
        let lines = EpicStatus.lines(for: paused, in: pausedSnapshot, now: now)
        #expect(lines.first?.text == "一時停止しています（2分）。再開するまで次の作業を始めません")
        #expect(lines.count == 2)
        #expect(EpicStatus.isPausedByYou(paused))

        try await service.perform(.resume(epicID: Self.epicID))
        let resume = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(resume.kind == ResumeEpicIntent.kind)
        #expect(resume.targetVersion == nil)
        let resumed = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(!resumed.isPaused)
        #expect(resumed.history.last?.text == "再開しました。司令塔が受け取るのを待っています")
    }

    /// Mac がオフラインで止まったジョブは、人の一時停止とは分けて「オフライン」と出す。再開は送れず、引き継ぎは送れる
    @Test
    func jobWaitingForOfflineMacIsNotHumanPause() async throws {
        var files = Self.pausableEpic(reviewing: "paused", waiting: "succeeded")
        files["\(Self.pauseBase)/attempts/\(Self.reviewingJobID)/1.json"] = Self.runningAttempt(Self.reviewingJobID, heartbeatAt: "06:00")
        let service = try makeService(files: files).service
        let snapshot = try await service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(!epic.isPaused)
        let since = try #require(ISO8601DateFormatter().date(from: "2027-01-15T07:10:00Z"))
        #expect(epic.activities.map(\.kind) == [.paused(macID: "mac-mini", since: since)])
        #expect(!EpicStatus.isPausedByYou(epic))
        #expect(service.supports(.pause(epicID: Self.epicID)))
        #expect(!service.supports(.resume(epicID: Self.epicID)))
        #expect(service.supports(.handOver(epicID: Self.epicID, macID: "")))
    }

    /// 引き継ぎは移す先の Mac を送り、司令塔が受け取るまでも移す先の Mac で出す。今の Mac・形の違う名前は送らない
    @Test
    func handOverIsSentWithMac() async throws {
        let fixture = try makeService(files: Self.pausableEpic(reviewing: "succeeded"))
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        await #expect(throws: ClientServiceError(message: "いま回している Mac です。ほかの Mac を選んでください")) {
            try await service.perform(.handOver(epicID: Self.epicID, macID: "mac-mini"))
        }
        await #expect(throws: ClientServiceError(message: "Mac の名前の形が違います")) {
            try await service.perform(.handOver(epicID: Self.epicID, macID: "MacBook B"))
        }

        try await service.perform(.handOver(epicID: Self.epicID, macID: "macbook-b"))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == HandoverIntent.kind)
        #expect(envelope.targetVersion == nil)
        #expect(envelope.payload == ["mac": .string("macbook-b")])
        let snapshot = try await service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(epic.macID == "macbook-b")
        #expect(epic.history.last?.text == "macbook-b に引き継ぎました。司令塔が受け取るのを待っています")
        #expect(snapshot.sentIntents.first?.title == "引き継ぎ（macbook-b） · ランキング")
    }

    /// 開始する前の epic は、一時停止も引き継ぎもできない
    @Test
    func pauseAndHandOverNeedStartedEpic() async throws {
        let service = try makeService().service
        _ = try await service.fetchSnapshot()
        #expect(!service.supports(.pause(epicID: Self.epicID)))
        #expect(!service.supports(.resume(epicID: Self.epicID)))
        #expect(!service.supports(.handOver(epicID: Self.epicID, macID: "")))
        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.pause(epicID: Self.epicID))
        }
    }
}
