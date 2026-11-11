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
        let blocked = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        let blocker = try #require(blocked.blocker)
        // 止まっている説明は、機械が書いているとは出さない
        #expect(!blocked.activities.contains { $0.kind == .explaining("Q1") })
        #expect(blocker.category == .authExpired)
        #expect(blocker.title == "Q1 の説明が止まっています")
        #expect(blocker.summary == "Claude のトークンの期限が切れた")
        #expect(blocker.logExcerpt == "401 Unauthorized")
        #expect(blocker.attempts.map(\.number) == [1, 2])
        #expect(blocker.attempts.first?.outcome == "Claude の障害: Claude が混み合っている")
        // 認証切れは人が直してから再開する。説明は、その作業だけをやめられる
        #expect(blocker.actions == [.resumeAfterFix, .cancelJob])
        #expect(blocker.target == "\(Self.jobID)/2")
        #expect(service.supports(.resolveBlocker(epicID: Self.epicID, action: .resumeAfterFix, instruction: "")))
        #expect(!service.supports(.resolveBlocker(epicID: Self.epicID, action: .fixWithInstruction, instruction: "")))
        // 出していない操作（説明は epic ごとにはやめない）は送れない
        #expect(!service.supports(.resolveBlocker(epicID: Self.epicID, action: .discard, instruction: "")))

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .resumeAfterFix, instruction: "", target: blocker.target))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == RetryJobIntent.kind)
        #expect(envelope.repo?.rawValue == Self.repo)
        #expect(envelope.target == IntentEnvelope.Target(type: JobTarget.targetType, epic: ULID(rawValue: Self.epicID), id: Self.jobID))
        #expect(envelope.targetVersion == "2")

        // 処理を待つ間は出さない
        let waiting = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(waiting.blocker == nil)
        #expect(waiting.activities.contains { $0.kind == .explaining("Q1") })
        // 履歴は古い順（画面は新しい順に並べ替えて、新しい 5 件を出す）
        #expect(waiting.history.last?.text.hasPrefix("Q1 の説明のやり直しを頼みました") == true)

        // やり直した試行もまた人に渡された（試行が進んだ）なら、もう一度出す
        await put(Self.job(kind: "explain", attempts: 3, input: Self.explainInput), at: Self.jobPath(), in: fixture.store)
        let again = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.blocker)
        #expect(again.summary == "失敗の理由は書かれていません")
    }

    /// 直しの上限を超えて試行の前に人に渡された直し（試行 0）も出し、やり直しは試行の番号 0 を付けて送る
    @Test
    func fixHandedOverBeforeAnyAttemptIsRetriedWithAttemptZero() async throws {
        let input = #"{"pullRequest":41,"head":"\#(String(repeating: "a", count: 40))","reason":"ci"}"#
        let files = Self.askingEpic(stage: "running", extra: [Self.jobPath(): Self.job(kind: "fixTask", attempts: 0, input: input)])
        let fixture = try makeService(files: files)
        let service = fixture.service
        let blocker = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.blocker)
        #expect(blocker.title == "タスクの修正が止まっています")
        #expect(blocker.attempts.isEmpty)
        // 直しをやめる扱いはまだ決めていない（司令塔も断る）ので、やり直しだけを出す
        #expect(blocker.actions == [.retry])
        #expect(blocker.target == "\(Self.jobID)/0")

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .retry, instruction: "", target: blocker.target))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == RetryJobIntent.kind)
        #expect(envelope.targetVersion == "0")
        // 処理を待つ間は出さない
        #expect(try await service.fetchSnapshot().epic(Self.epicID)?.blocker == nil)
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

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .cancelJob, instruction: "", target: before.blocker?.target))
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

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .discard, instruction: "", target: blocker.target))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == GiveUpJobIntent.kind)
        let abandoned = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(abandoned.isAbandoned)
        #expect(abandoned.blocker == nil)

        await consumed(envelope, result: "rejected", reason: "ジョブは人の対応を待っていない", in: fixture)
        let rejected = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(!rejected.isAbandoned)
        #expect(rejected.blocker != nil)
        #expect(rejected.history.last?.text == "取りやめ（着手前の確認）を受け付けませんでした: ジョブは人の対応を待っていない")
        #expect(rejected.history.last?.isFailure == true)
        #expect(rejected.history.map(\.date) == rejected.history.map(\.date).sorted())
    }

    /// 開始した後の epic に残っていた着手前の確認は、司令塔と同じく、epic ごとではなくその作業だけをやめる
    @Test(arguments: ["running", "finalizing", "reviewing"])
    func givingUpPlanningJobOfStartedEpicKeepsEpic(stage: String) async throws {
        let failure = #"{"class":"unexpected","message":"結果の形が違う"}"#
        let job = Self.waitingJob(kind: "checkReadiness", input: #"{"round":1}"#, lastFailure: failure)
        let fixture = try makeService(files: Self.askingEpic(stage: stage, extra: job))
        let service = fixture.service
        let blocker = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.blocker)
        #expect(blocker.title == "着手前の確認が止まっています")
        #expect(blocker.actions == [.retry, .cancelJob])
        #expect(!service.supports(.resolveBlocker(epicID: Self.epicID, action: .discard, instruction: "")))

        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .cancelJob, instruction: "", target: blocker.target))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == GiveUpJobIntent.kind)
        #expect(envelope.targetVersion == "2")
        // 処理を待つ間も、epic をやめたようには出さない
        let epic = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(!epic.isAbandoned)
        #expect(epic.blocker == nil)
        #expect(epic.history.last?.text == "着手前の確認をやめました。司令塔が受け取るのを待っています")
    }

    /// 開始を待つ epic にゴールの修正を送って受け付けられ、その修正のジョブが人に渡された状態。`origin` は修正の意図
    private func revisingEpicWithWaitingJob() async throws -> (fixture: Fixture, origin: String) {
        let goal = """
        {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
         "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"pending"}],"humanTasks":[]}
        """
        let goalPath = "repos/\(Self.repo)/epics/\(Self.epicID)/goal.json"
        let fixture = try makeService(files: Self.askingEpic(stage: "awaitingStart", extra: [goalPath: goal]))
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.reviseGoal(epicID: Self.epicID, request: "通知も足す"))
        let revise = try await sentEnvelope(in: fixture.store, key: fixture.key)
        await consumed(revise, result: "accepted", in: fixture)
        let origin = #"{"keyId":"\#(revise.keyId.rawValue)","nonce":"\#(revise.nonce.rawValue)"}"#
        await put(Self.job(kind: "reviseGoal", attempts: 1, origin: origin), at: Self.jobPath(), in: fixture.store)
        return (fixture, origin)
    }

    /// 受け付けたゴールの修正のジョブが人に渡されたら、直しているとは出さず、やめたら前のゴールのまま開始できる
    @Test
    func givingUpGoalRevisionLetsEpicStart() async throws {
        let (fixture, origin) = try await revisingEpicWithWaitingJob()
        let service = fixture.service
        let blocked = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(blocked.goal?.isRevising == true)
        #expect(!blocked.activities.contains { $0.kind == .revisingGoal })
        #expect(blocked.blocker?.title == "ゴールの修正が止まっています")
        #expect(blocked.blocker?.actions == [.retry, .cancelJob])

        let target = blocked.blocker?.target
        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .cancelJob, instruction: "", target: target))
        #expect(try await service.fetchSnapshot().epic(Self.epicID)?.goal?.isRevising == false)

        // 司令塔がやめるを受け付けてジョブを取り消した後も、修正の途中とは出さない
        await put(Self.job(kind: "reviseGoal", state: "canceled", attempts: 1, origin: origin), at: Self.jobPath(), in: fixture.store)
        let canceled = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(canceled.goal?.isRevising == false)
        #expect(canceled.blocker == nil)
    }

    /// 人に渡されたゴールの修正にやり直しを送ったら、処理を待つ間は直している途中として「いま」に出す
    @Test
    func retryingGoalRevisionShowsRevising() async throws {
        let service = try await revisingEpicWithWaitingJob().fixture.service
        let target = try await service.fetchSnapshot().epic(Self.epicID)?.blocker?.target
        try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .retry, instruction: "", target: target))

        let retrying = try #require(try await service.fetchSnapshot().epic(Self.epicID))
        #expect(retrying.blocker == nil)
        #expect(retrying.goal?.isRevising == true)
        #expect(retrying.activities.contains { $0.kind == .revisingGoal })
    }

    /// 送れなかった操作を送り直すまでに「対処が要ります」のジョブが替わっていたら、別のジョブには送らない
    @Test
    func staleBlockerActionIsNotSent() async throws {
        let fixture = try makeService(files: Self.explainingEpic())
        let service = fixture.service
        let stale = try #require(try await service.fetchSnapshot().epic(Self.epicID)?.blocker?.target)
        // 説明のジョブが片付き、着手前の確認のジョブが人に渡された
        await put(Self.job(kind: "explain", state: "canceled", input: Self.explainInput), at: Self.jobPath(), in: fixture.store)
        let other = "01JCJ0B0000000000000000005"
        let readiness = Self.job(kind: "checkReadiness", id: other, attempts: 1, input: #"{"round":1}"#)
        await put(readiness, at: Self.jobPath(other), in: fixture.store)
        #expect(try await service.fetchSnapshot().epic(Self.epicID)?.blocker?.target == "\(other)/1")

        await #expect(throws: ClientServiceError.self) {
            try await service.perform(.resolveBlocker(epicID: Self.epicID, action: .cancelJob, instruction: "", target: stale))
        }
        let sent = try await fixture.store.listAll("\(StatePath.intents)/\(fixture.key.keyID.rawValue)") ?? []
        #expect(sent.isEmpty)
    }

    /// 人の対応を待つジョブが複数あれば、古く止まったものから出し、残りの件数を添える
    @Test
    func oldestWaitingJobIsShownFirst() async throws {
        // 新しく止まったジョブの id を小さくして、id の順でなく止まった時刻の順で選ぶことを確かめる
        let newer = "01JCJ0B0000000000000000000"
        var files = Self.explainingEpic()
        files[Self.jobPath(newer)] = Self.job(
            kind: "reviseQuestion", id: newer, attempts: 0, input: #"{"question":"q2"}"#, updatedAt: "2026-11-01T02:00:00Z"
        )
        let snapshot = try await makeService(files: files).service.fetchSnapshot()
        let blocker = try #require(snapshot.epic(Self.epicID)?.blocker)
        #expect(blocker.title == "Q1 の説明が止まっています")
        #expect(blocker.summary.contains("ほかに 1 件の作業も対処を待っています"))
    }

    /// 置き場所と中身の合わないジョブ（ほかの epic のジョブの写し）は出さず、読めないものとして出す
    @Test
    func misplacedJobIsNotShown() async throws {
        let otherEpic = "01JCEP1C000000000000000009"
        var files = Self.explainingEpic()
        files[Self.jobPath()] = Self.job(kind: "explain", input: Self.explainInput).replacingOccurrences(of: Self.epicID, with: otherEpic)
        let snapshot = try await makeService(files: files).service.fetchSnapshot()
        #expect(snapshot.epic(Self.epicID)?.blocker == nil)
        #expect(snapshot.sourceFailures.contains { $0.source == Self.jobPath() && $0.message == StateReader.misplaced })
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
