@testable import AskHub
import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 人に渡されたジョブ: 「対処が要ります」に出すこと、やり直す・やめるを試行の番号つきで送ること、処理を待つ間の出し方
extension StateClientServiceTests {
    static let jobID = "01JCJ0B0000000000000000001"
    private static let askedKey = "3GHenKEuXhau_ydZhSS8zpDFx5A1_I5K_ZMmfZsTw1Y"
    private static let explainInput = #"{"question":"q1","asked":{"keyId":"\#(askedKey)","nonce":"01JCN0NCE00000000000000002"}}"#

    private static func jobPath(_ id: String = jobID) -> String {
        "repos/\(repo)/epics/\(epicID)/jobs/\(id).json"
    }

    private static func job(
        kind: String,
        id: String = jobID,
        state: String = "waitingHuman",
        attempts: Int = 2,
        input: String = "null",
        origin: String = "null",
        updatedAt: String = "2026-11-01T01:30:00Z"
    ) -> String {
        """
        {"v":1,"id":"\(id)","kind":"\(kind)","repo":"\(repo)","epic":"\(epicID)","assignedMac":"mac-mini",
         "needs":{"claude":true,"build":false},"dependsOn":[],"state":"\(state)","attempts":\(attempts),"input":\(input),"origin":\(origin),
         "createdAt":"2026-11-01T01:00:00Z","updatedAt":"\(updatedAt)"}
        """
    }

    /// 人の対応を待っているジョブと、その 2 回の試行（1 回目は Claude の障害、2 回目が最後の失敗）
    private static func waitingJob(
        kind: String,
        input: String = "null",
        lastFailure: String = #"{"class":"authExpired","message":"Claude のトークンの期限が切れた","logExcerpt":"401 Unauthorized"}"#
    ) -> [String: String] {
        let attempts = "repos/\(repo)/epics/\(epicID)/attempts/\(jobID)"
        return [
            jobPath(): job(kind: kind, input: input),
            "\(attempts)/1.json": """
            {"v":1,"job":"\(jobID)","n":1,"mac":"mac-mini","startedAt":"2026-11-01T01:00:00Z","heartbeatAt":"2026-11-01T01:00:00Z",
             "endedAt":"2026-11-01T01:05:00Z","outcome":"failed","failure":{"class":"claudeOutage","message":"Claude が混み合っている"}}
            """,
            "\(attempts)/2.json": """
            {"v":1,"job":"\(jobID)","n":2,"mac":"mac-mini","startedAt":"2026-11-01T01:20:00Z","heartbeatAt":"2026-11-01T01:20:00Z",
             "endedAt":"2026-11-01T01:30:00Z","outcome":"failed","failure":\(lastFailure)}
            """
        ]
    }

    /// Q1 の説明を頼んで、説明を待っている質問
    private static let clarifyingQuestions = [
        "repos/\(repo)/epics/\(epicID)/questions.json": """
        {"v":1,"questions":[
          {"id":"q1","version":2,"title":"ランキングの単位","why":"集計と画面に関わる",
           "options":[{"label":"日ごと","effect":"毎日入れ替わる"},{"label":"週ごと","effect":"集計の保存が要る"}],
           "recommended":"日ごと","reason":"今の仕組みのまま作れる","dependsOn":[],"round":1,"state":"clarifying",
           "explanations":[
             {"asked":{"keyId":"\(askedKey)","nonce":"01JCN0NCE00000000000000002"},"note":"集計の保存とは？","at":"2026-11-01T01:00:00Z"}
           ]}
        ]}
        """
    ]

    private static func explainingEpic() -> [String: String] {
        askingEpic(extra: clarifyingQuestions.merging(waitingJob(kind: "explain", input: explainInput)) { _, new in new })
    }

    private func put(_ text: String, at path: String, in store: InMemoryStateStore) async {
        await store.put(path, data: Data(text.utf8))
    }

    private func consumed(_ envelope: IntentEnvelope, result: String, reason: String? = nil, in fixture: Fixture) async {
        let reason = reason.map { #","reason":"\#($0)""# } ?? ""
        let record = #"{"v":1,"kind":"\#(envelope.kind)","consumedAt":"2027-01-15T08:00:00Z","result":"\#(result)"\#(reason)}"#
        await put(record, at: StatePath.consumed(device: fixture.key.keyID, nonce: envelope.nonce), in: fixture.store)
    }

    /// 人の対応を待っているジョブは、最後の試行の失敗・試したこと・選べる操作を出し、やり直しは見たときの試行の番号を付けて送る
    @Test
    func waitingJobIsShownAsBlockerAndRetried() async throws {
        let fixture = try makeService(files: Self.explainingEpic())
        let service = fixture.service
        let blocker = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.blocker)
        #expect(blocker.category == .authExpired)
        #expect(blocker.title == "Q1 の説明が止まっています")
        #expect(blocker.summary == "Claude のトークンの期限が切れた")
        #expect(blocker.logExcerpt == "401 Unauthorized")
        #expect(blocker.attempts.map(\.number) == [1, 2])
        #expect(blocker.attempts.first?.outcome == "Claude の障害: Claude が混み合っている")
        // 認証切れは人が直してから再開する。説明は、その作業だけをやめられる
        #expect(blocker.actions == [.resumeAfterFix, .cancelJob])
        #expect(service.supports(.resolveBlocker(epicID: Self.epicID, action: .resumeAfterFix, instruction: "")))
        #expect(!service.supports(.resolveBlocker(epicID: Self.epicID, action: .fixWithInstruction, instruction: "")))

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .resumeAfterFix, instruction: ""))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == RetryJobIntent.kind)
        #expect(envelope.repo?.rawValue == Self.repo)
        #expect(envelope.target == IntentEnvelope.Target(type: JobTarget.targetType, epic: ULID(rawValue: Self.epicID), id: Self.jobID))
        #expect(envelope.targetVersion == "2")

        // 処理を待つ間は出さない
        let waiting = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(waiting.blocker == nil)
        #expect(waiting.history.contains { $0.text.hasPrefix("Q1 の説明のやり直しを頼みました") })

        // やり直した試行もまた人に渡された（試行が進んだ）なら、もう一度出す
        await put(Self.job(kind: "explain", attempts: 3, input: Self.explainInput), at: Self.jobPath(), in: fixture.store)
        let again = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.blocker)
        #expect(again.summary == "失敗の理由は書かれていません")
    }

    /// 説明をやめると、処理を待つ間は質問を回答待ちに戻して出す
    @Test
    func givingUpExplanationReopensQuestion() async throws {
        let fixture = try makeService(files: Self.explainingEpic())
        let service = fixture.service
        let before = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        guard case .awaitingExplanation = before.question("Q1")?.state else {
            Issue.record("説明を待つ質問になっていない: \(String(describing: before.question("Q1")?.state))")
            return
        }

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .cancelJob, instruction: ""))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == GiveUpJobIntent.kind)
        #expect(envelope.targetVersion == "2")

        let epic = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(epic.blocker == nil)
        #expect(epic.question("Q1")?.state == .open)
        #expect(epic.question("Q1")?.explanations.isEmpty == true)
        #expect(!epic.activities.contains { $0.kind == .explaining("Q1") })
        #expect(!epic.isAbandoned)
    }

    /// やめると先に進めないジョブ（着手前の確認など）をやめると、epic ごとやめる。受け付けなかったら、理由を出して元に戻す
    @Test
    func givingUpBlockingJobAbandonsEpicUntilRejected() async throws {
        let failure = #"{"class":"unexpected","message":"結果の形が違う"}"#
        let job = Self.waitingJob(kind: "checkReadiness", input: #"{"round":1}"#, lastFailure: failure)
        let files = Self.askingEpic(stage: "checking", extra: job)
        let fixture = try makeService(files: files)
        let service = fixture.service
        let blocker = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.blocker)
        #expect(blocker.title == "着手前の確認が止まっています")
        #expect(blocker.category == .unexpected)
        #expect(blocker.actions == [.retry, .discard])

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .discard, instruction: ""))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == GiveUpJobIntent.kind)
        let abandoned = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(abandoned.isAbandoned)
        #expect(abandoned.blocker == nil)

        await consumed(envelope, result: "rejected", reason: "ジョブは人の対応を待っていない", in: fixture)
        let rejected = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(!rejected.isAbandoned)
        #expect(rejected.blocker != nil)
        #expect(rejected.history.contains { $0.isFailure && $0.text == "取りやめ（着手前の確認）を受け付けませんでした: ジョブは人の対応を待っていない" })
    }

    /// 受け付けたゴールの修正のジョブが人に渡されたら、直しているとは出さず、やめたら前のゴールのまま開始できる
    @Test
    func givingUpGoalRevisionLetsEpicStart() async throws {
        let goal = """
        {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
         "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"pending"}],"humanTasks":[]}
        """
        let goalPath = "repos/\(Self.repo)/epics/\(Self.epicID)/goal.json"
        let fixture = try makeService(files: Self.askingEpic(stage: "awaitingStart", extra: [goalPath: goal]))
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        try await service.perform(.reviseGoal(epicID: Self.epicID, request: "通知も足す"))
        let revise = try await sentEnvelope(in: fixture.store, key: fixture.key)
        await consumed(revise, result: "accepted", in: fixture)
        let origin = #"{"keyId":"\#(revise.keyId.rawValue)","nonce":"\#(revise.nonce.rawValue)"}"#
        await put(Self.job(kind: "reviseGoal", attempts: 1, origin: origin), at: Self.jobPath(), in: fixture.store)

        let blocked = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(blocked.goal?.isRevising == true)
        #expect(!blocked.activities.contains { $0.kind == .revisingGoal })
        #expect(blocked.blocker?.title == "ゴールの修正が止まっています")
        #expect(blocked.blocker?.actions == [.retry, .cancelJob])

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .cancelJob, instruction: ""))
        #expect(try await service.fetchSnapshot().epic(Self.epicID)?.goal?.isRevising == false)

        // 司令塔がやめるを受け付けてジョブを取り消した後も、修正の途中とは出さない
        await put(Self.job(kind: "reviseGoal", state: "canceled", attempts: 1, origin: origin), at: Self.jobPath(), in: fixture.store)
        let canceled = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(canceled.goal?.isRevising == false)
        #expect(canceled.blocker == nil)
    }

    /// 人の対応を待つジョブが複数あれば、古く止まったものから出し、残りの件数を添える
    @Test
    func oldestWaitingJobIsShownFirst() async throws {
        let newer = "01JCJ0B0000000000000000009"
        var files = Self.explainingEpic()
        files[Self.jobPath(newer)] = Self.job(
            kind: "reviseQuestion", id: newer, attempts: 0, input: #"{"question":"q2"}"#, updatedAt: "2026-11-01T02:00:00Z"
        )
        let snapshot = try await makeService(files: files).service.fetchSnapshot()
        let blocker = try #require(snapshot.epic(Self.epicID)?.blocker)
        #expect(blocker.title == "Q1 の説明が止まっています")
        #expect(blocker.summary.contains("ほかに 1 件の作業も対処を待っています"))
    }

    /// 終わった（マージした・やめた）epic のジョブは読まない
    @Test
    func jobsOfFinishedEpicsAreNotRead() async throws {
        for stage in ["merged", "abandoned", "asking"] {
            let files = Self.askingEpic(stage: stage, extra: [Self.jobPath(): "読めないジョブ"])
            let snapshot = try await makeService(files: files).service.fetchSnapshot()
            #expect(snapshot.sourceFailures.contains { $0.source == Self.jobPath() } == (stage == "asking"), "\(stage)")
            #expect(snapshot.epic(Self.epicID)?.blocker == nil)
        }
    }
}
