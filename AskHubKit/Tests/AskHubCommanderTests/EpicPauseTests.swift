@testable import AskHubCommander
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 開始した epic の一時停止・再開・ほかの Mac への引き継ぎ（人の意図の受け付けと、`JobSweep`・`TaskFlow` でのジョブの扱い）
struct EpicPauseTests {
    static let repo = EpicHandlersTests.repo
    static let commander = EpicHandlersTests.commander
    static let laptop = EpicHandlersTests.laptop
    static let other = MacName(rawValue: "macbook-b")!
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let origin = TaskFlowTests.origin

    let store = InMemoryStateStore()
    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }

    func context(at now: Date = Self.now) -> CommanderContext {
        CommanderContext(store: store, mac: Self.commander) { now }
    }

    func intake(at now: Date = Self.now) -> IntentIntake {
        IntentIntake(
            context: context(at: now),
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: CommanderLoop.handlers(admin: nil)
        )
    }

    /// 人の意図を置いて処理する。置いた順に処理されるよう、番号の時刻を秒でずらす（LEARNINGS の「司令塔のテストで人の意図を続けて置くとき」）
    func send(_ kind: String, payload: [String: JSONValue] = [:], at offset: TimeInterval = 0) async throws -> [IntakeOutcome] {
        let issued = Self.now.addingTimeInterval(offset)
        let nonce = ULID.generate(at: issued)
        let envelope = IntentEnvelope(
            kind: kind,
            repo: Self.repo,
            target: .init(type: "epic", epic: Self.epicID),
            payload: payload,
            issuedAt: Timestamp(issued),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        return try await intake(at: issued).processPending()
    }

    func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    func read<File: StateFile>(_ type: File.Type, at path: String) async throws -> File? {
        try await store.data(at: path).map { try StateFileCoder.decode(File.self, from: $0) }
    }

    func epic() async throws -> EpicFile {
        try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, Self.epicID)))
    }

    func job(_ job: JobFile) async throws -> JobFile {
        try #require(try await read(JobFile.self, at: StatePath.job(Self.repo, epic: Self.epicID, job: job.id)))
    }

    func sweep(at now: Date = Self.now) async throws -> JobSweep.Swept {
        try await JobSweep(context: context(at: now)).sweepAll()
    }

    /// 対象のリポジトリ・Mac の生きている印・開始した epic（`stage`）・ゴール（t1 → t2）。`prepared` なら作業場所の用意が成功している
    @discardableResult
    func started(stage: EpicStage = .running, prepared: Bool = true, laptopSeen: Date = Self.now) async throws -> JobFile {
        let repository = RepositoryFile(repo: Self.repo, platform: .apple, maxConcurrentEpics: 1, addedAt: Timestamp(Self.now))
        try await put(repository, at: StatePath.repository(Self.repo))
        try await mac(Self.laptop, seen: laptopSeen)
        try await mac(Self.other, seen: Self.now)
        let time = Timestamp(Self.now)
        let mac: MacName? = stage == .awaitingStart ? nil : Self.laptop
        let epic = EpicFile(
            id: Self.epicID, repo: Self.repo, title: "ランキング", stage: stage, mac: mac, goalVersion: 1, createdAt: time, updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, Self.epicID))
        let tasks: [GoalFile.Task] = [.init(id: "t1", title: "集計を作る"), .init(id: "t2", title: "画面を作る", dependsOn: ["t1"])]
        let goal = GoalFile(version: 1, summary: "ランキングを作る", doneWhen: ["…"], tasks: tasks)
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID))
        let spec = JobSpec(kind: .prepareWorkspace, mac: Self.laptop, needs: .init(claude: false, build: false))
        var prepare = context().job(spec, for: epic, origin: Self.origin, seed: "")
        if prepared {
            prepare.state = .succeeded
            prepare.attempts = 1
            let outputs = AttemptFile.Outputs(commit: TaskFlowTests.sha("0"), branch: "askhub/\(Self.epicID)")
            try await attempt(of: prepare, number: 1, outcome: .succeeded, outputs: outputs)
        }
        try await put(prepare, at: StatePath.job(Self.repo, epic: Self.epicID, job: prepare.id))
        return prepare
    }

    func mac(_ name: MacName, seen: Date) async throws {
        let check = SelfCheck(checkedAt: Timestamp(seen), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let file = MacFile(
            mac: name,
            kind: .resident,
            seenAt: Timestamp(seen),
            versions: .init(worker: "1.0.0"),
            diskFreeGB: 100,
            load: 1,
            capacity: .init(claude: 1, build: 1),
            selfCheck: check
        )
        try await put(file, at: StatePath.mac(name))
    }

    /// epic のジョブを置く
    @discardableResult
    func placed(
        _ kind: JobKind,
        seed: String,
        mac: MacName = Self.laptop,
        state: JobState = .assigned,
        attempts: Int = 0
    ) async throws -> JobFile {
        let epic = try await epic()
        let spec = JobSpec(kind: kind, mac: mac, needs: .init(claude: true, build: true))
        var job = context().job(spec, for: epic, origin: Self.origin, seed: seed)
        job.task = TaskFlow.taskKinds.contains(kind) ? "t1" : nil
        job.state = state
        job.attempts = attempts
        try await put(job, at: StatePath.job(Self.repo, epic: Self.epicID, job: job.id))
        return job
    }

    /// 試行を書く（`at` は開始と生きている印の時刻）
    func attempt(
        of job: JobFile,
        number: Int,
        mac: MacName = Self.laptop,
        outcome: AttemptOutcome,
        failure: FailureClass? = nil,
        outputs: AttemptFile.Outputs? = nil,
        at time: Date = Self.now
    ) async throws {
        let stamp = Timestamp(time)
        let file = AttemptFile(
            job: job.id,
            number: number,
            mac: mac,
            startedAt: stamp,
            heartbeatAt: stamp,
            endedAt: outcome == .running ? nil : stamp,
            outcome: outcome,
            failure: failure.map { AttemptFailure(failureClass: $0, message: "テスト") },
            outputs: outputs
        )
        try await put(file, at: StatePath.attempt(Self.repo, epic: Self.epicID, job: job.id, number: number))
    }

    func advance(at now: Date = Self.now) async throws -> TaskFlow.Advanced {
        let swept = try await sweep(at: now)
        return await TaskFlow(context: context(at: now)).advance(epics: swept.epics, jobs: swept.jobs)
    }

    // MARK: - 一時停止と再開

    /// 一時停止の間は次のジョブを作らず、再開したら作る
    @Test func pauseStopsNewJobsUntilResumed() async throws {
        try await started()
        #expect(try await send("pauseEpic") == [.accepted(kind: "pauseEpic")])
        let pause = try #require(try await epic().pause)
        #expect(pause.since == Timestamp(Self.now))
        #expect(pause.origin.keyId == keyID)
        // 作業場所の用意は済んでいるが、最初のタスクの実装を作らない
        #expect(try await advance().created.isEmpty)
        #expect(try await read(GoalFile.self, at: StatePath.goal(Self.repo, Self.epicID))?.tasks.map(\.state) == [.pending, .pending])

        #expect(try await send("resumeEpic", at: 60) == [.accepted(kind: "resumeEpic")])
        #expect(try await epic().pause == nil)
        let created = try await advance(at: Self.now.addingTimeInterval(60)).created
        #expect(created.map(\.kind) == [.implementTask])
        #expect(created.first?.assignedMac == Self.laptop)
    }

    /// まだ動いていないジョブは止め、動いているジョブは最後まで終わらせる。終わっても次のジョブは作らない
    @Test func pauseHoldsWaitingJobsAndLetsRunningJobFinish() async throws {
        try await started()
        let waiting = try await placed(.implementTask, seed: "t1")
        let running = try await placed(.reviewTask, seed: "r1", state: .running, attempts: 1)
        try await attempt(of: running, number: 1, outcome: .running)
        #expect(try await send("pauseEpic") == [.accepted(kind: "pauseEpic")])
        _ = try await sweep()
        #expect(try await job(waiting).state == .paused)
        #expect(try await job(running).state == .running)
        // もう一度見ても書き直さない
        #expect(try await JobSweep(context: context()).sweep().isEmpty)

        let merged = AttemptFile.Outputs(pullRequest: 41, commit: TaskFlowTests.sha("1"), verdict: .merged)
        try await attempt(of: running, number: 1, outcome: .succeeded, outputs: merged)
        let advanced = try await advance()
        #expect(try await job(running).state == .succeeded)
        #expect(advanced.created.isEmpty)
        #expect(try await job(waiting).state == .paused)

        #expect(try await send("resumeEpic", at: 60) == [.accepted(kind: "resumeEpic")])
        _ = try await sweep(at: Self.now.addingTimeInterval(60))
        #expect(try await job(waiting).state == .assigned)
    }

    /// 開始する前は一時停止できない。止めている間にもう一度止めても、同じ印のまま受け付ける
    @Test func pauseOnlyAfterStartAndTwiceIsHarmless() async throws {
        try await started(stage: .awaitingStart, prepared: false)
        #expect(try await send("pauseEpic") == [.rejected(kind: "pauseEpic", reason: "開始した後だけ一時停止できる（今は awaitingStart）")])

        try await started(stage: .reviewing)
        #expect(try await send("pauseEpic", at: 1) == [.accepted(kind: "pauseEpic")])
        let first = try #require(try await epic().pause)
        #expect(try await send("pauseEpic", at: 2) == [.accepted(kind: "pauseEpic")])
        #expect(try await epic().pause == first)
        // 止めていない epic の再開も受け付ける（何もしない）
        #expect(try await send("resumeEpic", at: 3) == [.accepted(kind: "resumeEpic")])
        #expect(try await send("resumeEpic", at: 4) == [.accepted(kind: "resumeEpic")])
        #expect(try await epic().pause == nil)
    }

    /// Mac がオフラインで止まったジョブは、再開しても動かさない（同じ Mac が戻るのを待つ）
    @Test func resumeLeavesJobWaitingForOfflineMac() async throws {
        // macbook の印は 2 時間前（オフライン）。実装の試行は 1 時間前から止まっている
        try await started(laptopSeen: Self.now.addingTimeInterval(-2 * 3600))
        let stuck = try await placed(.implementTask, seed: "t1", state: .running, attempts: 1)
        try await attempt(of: stuck, number: 1, outcome: .running, at: Self.now.addingTimeInterval(-3600))
        let held = try await placed(.reviewTask, seed: "r1")
        #expect(try await send("pauseEpic") == [.accepted(kind: "pauseEpic")])
        _ = try await sweep()
        #expect(try await job(stuck).state == .paused)
        #expect(try await job(held).state == .paused)

        #expect(try await send("resumeEpic", at: 60) == [.accepted(kind: "resumeEpic")])
        _ = try await sweep(at: Self.now.addingTimeInterval(60))
        #expect(try await job(stuck).state == .paused)
        #expect(try await job(held).state == .assigned)
    }

    /// 人がやり直しで戻したジョブは、一時停止の間も再開の後も、前の失敗で人の対応待ちに戻さない
    @Test func retriedJobIsNotRedecidedAcrossPause() async throws {
        try await started()
        let fix = try await placed(.fixTask, seed: "f1", attempts: 4)
        for number in 1...4 { try await attempt(of: fix, number: number, outcome: .failed, failure: .buildFailed) }
        #expect(try await send("pauseEpic") == [.accepted(kind: "pauseEpic")])
        _ = try await sweep()
        #expect(try await job(fix).state == .paused)
        _ = try await sweep(at: Self.now.addingTimeInterval(30))
        #expect(try await job(fix).state == .paused)

        #expect(try await send("resumeEpic", at: 60) == [.accepted(kind: "resumeEpic")])
        _ = try await sweep(at: Self.now.addingTimeInterval(60))
        let released = try await job(fix)
        #expect(released.state == .assigned)
        #expect(released.attempts == 4)
    }

    // MARK: - 引き継ぎ

    /// 一時停止していない epic は、前の Mac でジョブが動いている間は引き継げない
    @Test func handoverWaitsForRunningJobUnlessPaused() async throws {
        try await started()
        let running = try await placed(.implementTask, seed: "t1", state: .running, attempts: 1)
        try await attempt(of: running, number: 1, outcome: .running)
        let reason = "macbook でジョブ（implementTask）が動いている。一時停止して、動いているジョブが終わってから引き継ぐ"
        #expect(try await send("handover", payload: ["mac": .string("macbook-b")]) == [.rejected(kind: "handover", reason: reason)])
        #expect(try await epic().mac == Self.laptop)

        // 一時停止すれば、動いているジョブを待たずに受け付ける（動いているジョブは前の Mac で最後まで動く）
        #expect(try await send("pauseEpic", at: 1) == [.accepted(kind: "pauseEpic")])
        #expect(try await send("handover", payload: ["mac": .string("macbook-b")], at: 2) == [.accepted(kind: "handover")])
        #expect(try await epic().mac == Self.other)
        _ = try await sweep(at: Self.now.addingTimeInterval(2))
        let kept = try await job(running)
        #expect(kept.state == .running)
        #expect(kept.assignedMac == Self.laptop)

        // 前の Mac で失敗してやり直すときは、移す先に付け替えて止めたままにする
        try await attempt(of: running, number: 1, outcome: .failed, failure: .testFailed)
        _ = try await sweep(at: Self.now.addingTimeInterval(3))
        let retried = try await job(running)
        #expect(retried.state == .paused)
        #expect(retried.assignedMac == Self.other)
    }

    /// 引き継ぐと、動いていないジョブを移す先に付け替える。司令塔の Mac で動く最終 PR の段取りのジョブは触らない
    @Test func handoverMovesIdleJobsOfEpicMac() async throws {
        try await started(stage: .finalizing)
        let held = try await placed(.verifyBeforeFinal, seed: "v1")
        let waiting = try await placed(.fixFinalPullRequest, seed: "f1", state: .waitingHuman, attempts: 1)
        let review = try await placed(.reviewFinalPullRequest, seed: "r1", mac: Self.commander)
        #expect(try await send("handover", payload: ["mac": .string("macbook-b")]) == [.accepted(kind: "handover")])
        _ = try await sweep()
        #expect(try await job(held).assignedMac == Self.other)
        #expect(try await job(held).state == .assigned)
        #expect(try await job(waiting).assignedMac == Self.other)
        #expect(try await job(waiting).state == .waitingHuman)
        #expect(try await job(review).assignedMac == Self.commander)
        // 同じ Mac への引き継ぎは、もう一度送っても受け付ける（何もしない）
        #expect(try await send("handover", payload: ["mac": .string("macbook-b")], at: 1) == [.accepted(kind: "handover")])
    }

    /// 前の Mac がオフラインで止まったジョブは、前の Mac を待たずに移す先で取り出し直す。次のジョブも移す先に作る
    @Test func handoverFromOfflineMacRestartsStuckJobOnNewMac() async throws {
        try await started(laptopSeen: Self.now.addingTimeInterval(-2 * 3600))
        let stuck = try await placed(.reviewTask, seed: "r1", state: .running, attempts: 1)
        try await attempt(of: stuck, number: 1, outcome: .running, at: Self.now.addingTimeInterval(-3600))
        _ = try await sweep()
        #expect(try await job(stuck).state == .paused)

        // 移す先はオフラインでもよい
        try await mac(Self.other, seen: Self.now.addingTimeInterval(-2 * 3600))
        #expect(try await send("handover", payload: ["mac": .string("macbook-b")], at: 1) == [.accepted(kind: "handover")])
        let advanced = try await advance(at: Self.now.addingTimeInterval(1))
        let moved = try await job(stuck)
        #expect(moved.state == .assigned)
        #expect(moved.assignedMac == Self.other)
        #expect(advanced.created.map(\.kind) == [.implementTask])
        #expect(advanced.created.first?.assignedMac == Self.other)
        // 次の周でも、前の Mac の止まった試行で止め直さない
        _ = try await sweep(at: Self.now.addingTimeInterval(2))
        #expect(try await job(stuck).state == .assigned)
    }

    /// 開始する前・登録されていない Mac・形の違う Mac には引き継がない
    @Test func handoverRejectsBeforeStartAndUnknownMac() async throws {
        try await started(stage: .awaitingStart, prepared: false)
        let mac: [String: JSONValue] = ["mac": .string("macbook-b")]
        #expect(try await send("handover", payload: mac) == [.rejected(kind: "handover", reason: "開始した後だけ引き継げる（今は awaitingStart）")])

        try await started()
        let unknown = "Mac imac が登録されていない（ワーカーが一度も動いていない）"
        #expect(try await send("handover", payload: ["mac": .string("imac")], at: 1) == [.rejected(kind: "handover", reason: unknown)])
        let malformed = try await send("handover", payload: ["mac": .string("../mac")], at: 2)
        #expect(malformed == [.rejected(kind: "handover", reason: "引き継ぎの形が違う（mac の形が違う）")])
        #expect(try await epic().mac == Self.laptop)
    }
}
