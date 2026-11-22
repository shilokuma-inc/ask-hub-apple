@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 人がタスクを飛ばす（`skipTask`）: 受け付け・タスクの流れ・Claude に渡すゴール
struct TaskSkipTests {
    static let repo = EpicHandlersTests.repo
    static let laptop = EpicHandlersTests.laptop
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let origin = TaskFlowTests.origin
    static let nonce = ULID(rawValue: "01JCN0NCE000000000000000S1")!

    let store = InMemoryStateStore()
    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    var context: CommanderContext { CommanderContext(store: store, mac: EpicHandlersTests.commander) { Self.now } }
    var intent: IntentReference { IntentReference(keyId: keyID, nonce: Self.nonce) }

    private func intake() -> IntentIntake {
        IntentIntake(
            context: context,
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["skipTask": SkipTaskHandler()]
        )
    }

    private func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    private func goal() async throws -> GoalFile {
        try StateFileCoder.decode(GoalFile.self, from: #require(await store.data(at: StatePath.goal(Self.repo, Self.epicID))))
    }

    private func reread(_ job: JobFile) async throws -> JobFile {
        let path = StatePath.job(Self.repo, epic: Self.epicID, job: job.id)
        return try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: path)))
    }

    private func epic() async throws -> EpicFile {
        try StateFileCoder.decode(EpicFile.self, from: #require(await store.data(at: StatePath.epic(Self.repo, Self.epicID))))
    }

    private func jobs() async throws -> [JobFile] {
        var jobs: [JobFile] = []
        for entry in try await store.list(StatePath.jobs(Self.repo, epic: Self.epicID)) ?? [] {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }

    /// 署名したタスクを飛ばすの意図を `intents/` に置く
    private func skip(
        _ job: JobFile,
        attempt: Int,
        payload: [String: JSONValue] = ["reason": .string("handledElsewhere")],
        nonce: ULID = nonce
    ) async throws {
        let envelope = IntentEnvelope(
            kind: "skipTask",
            repo: Self.repo,
            target: .init(type: "job", epic: Self.epicID, id: job.id.rawValue),
            targetVersion: String(attempt),
            payload: payload,
            issuedAt: Timestamp(Self.now),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
    }

    /// 実装している epic と、ゴール（t1 は済み、t2 は `taskState`、t3 は t2 に依存）と、成功した作業場所の用意
    private func started(stage: EpicStage = .running, taskState: TaskState = .running, t3: Bool = true) async throws -> JobFile {
        let time = Timestamp(Self.now)
        let epic = EpicFile(
            id: Self.epicID,
            repo: Self.repo,
            title: "シェア",
            stage: stage,
            mac: Self.laptop,
            branch: "askhub/\(Self.epicID)",
            goalVersion: 1,
            createdAt: time,
            updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, Self.epicID))
        var tasks: [GoalFile.Task] = [
            .init(id: "t1", title: "カードを作る", state: .done),
            .init(id: "t2", title: "Android の仕様を直す", dependsOn: ["t1"], state: taskState)
        ]
        if t3 { tasks.append(.init(id: "t3", title: "文書を書く", dependsOn: ["t2"])) }
        try await put(GoalFile(summary: "シェアする", doneWhen: ["…"], tasks: tasks), at: StatePath.goal(Self.repo, Self.epicID))
        let spec = JobSpec(kind: .prepareWorkspace, mac: Self.laptop, needs: .init(claude: false, build: false))
        var prepare = context.job(spec, for: epic, origin: Self.origin, seed: "")
        prepare.state = .succeeded
        prepare.attempts = 1
        try await put(prepare, at: StatePath.job(Self.repo, epic: Self.epicID, job: prepare.id))
        return prepare
    }

    /// t2 の `kind` のジョブ（`state`・試行 `attempts`）を置く
    private func taskJob(
        _ kind: JobKind,
        state: JobState = .waitingHuman,
        attempts: Int = 1,
        input: (any JobInput)? = nil,
        seed: String
    ) async throws -> JobFile {
        let epic = try await epic()
        let needs = JobFile.Needs(claude: true, build: kind != .reviewTask)
        let spec = JobSpec(kind: kind, mac: Self.laptop, needs: needs, input: input?.jobInput ?? [:])
        var job = context.job(spec, for: epic, origin: Self.origin, seed: seed)
        job.task = "t2"
        job.state = state
        job.attempts = attempts
        try await put(job, at: StatePath.job(Self.repo, epic: Self.epicID, job: job.id))
        return job
    }

    // MARK: - 受け付け

    /// 人に渡した実装を飛ばす: タスクを skipped にして記録を書き、ジョブを取り消す。依存するタスクは、次の周で始める
    @Test func skippingWaitingImplementationMovesOnToDependentTask() async throws {
        try await started()
        let implement = try await taskJob(.implementTask, seed: "t2")
        try await skip(implement, attempt: 1, payload: ["reason": .string("handledElsewhere"), "note": .string("別の依頼で直す")])
        #expect(try await intake().processPending() == [.accepted(kind: "skipTask")])
        let task = try #require(try await goal().tasks.first { $0.id == "t2" })
        #expect(task.state == .skipped)
        #expect(task.skip == GoalFile.Skip(reason: .handledElsewhere, note: "別の依頼で直す", intent: intent, at: Timestamp(Self.now)))
        // 人が読むゴールの中身は変えないので、版は上げない
        #expect(try await goal().version == 1)
        #expect(try await reread(implement).state == .canceled)

        let epic = try await epic()
        let step = await TaskFlow(context: context).advance(epics: [epic], jobs: try await jobs())
        let next = try #require(step.created.first)
        #expect(next.kind == .implementTask)
        #expect(next.task == "t3")
        #expect(try await goal().tasks.map(\.state) == [.done, .skipped, .running])
    }

    /// 最後のタスクを飛ばすと、すべて済んだものとして最終 PR の段取りに進む
    @Test func skippingLastTaskStartsFinal() async throws {
        try await started(t3: false)
        let implement = try await taskJob(.implementTask, seed: "t2")
        try await skip(implement, attempt: 1, payload: ["reason": .string("notNeeded")])
        #expect(try await intake().processPending() == [.accepted(kind: "skipTask")])
        #expect(try await goal().tasks.last?.skip?.note == nil)
        let epic = try await epic()
        let step = await TaskFlow(context: context).advance(epics: [epic], jobs: try await jobs())
        #expect(step.created.map(\.kind) == [.verifyBeforeFinal])
        #expect(try await self.epic().stage == .finalizing)
    }

    /// 上限を超えた直し（試行の前に人に渡した）とレビューを飛ばすと、見ていた子 PR を記録に書く（最終 PR を出すときに閉じる）
    @Test(arguments: [JobKind.fixTask, .reviewTask])
    func skippingReviewOrFixRecordsChildPullRequest(kind: JobKind) async throws {
        try await started()
        let head = String(repeating: "a", count: 40)
        let input: any JobInput = kind == .fixTask
            ? FixTaskInput(pullRequest: 41, head: head, reason: .ci)
            : PullRequestInput(pullRequest: 41, head: head)
        let attempts = kind == .fixTask ? 0 : 2
        let waiting = try await taskJob(kind, attempts: attempts, input: input, seed: "fix")
        let other = try await taskJob(.reviewTask, state: .assigned, input: PullRequestInput(pullRequest: 41, head: head), seed: "other")
        try await skip(waiting, attempt: attempts)
        #expect(try await intake().processPending() == [.accepted(kind: "skipTask")])
        #expect(try await goal().tasks[1].skip?.pullRequest == 41)
        // 同じタスクの終わっていないジョブも取り消す
        #expect(try await reread(waiting).state == .canceled)
        #expect(try await reread(other).state == .canceled)
    }

    /// 前の周でタスクを飛ばした後に止まった（ジョブを取り消す前）: 記録は書き直さず、ジョブの取り消しだけをする
    @Test func redoingCancelsJobsWithoutRewritingRecord() async throws {
        try await started()
        let record = GoalFile.Skip(reason: .notNeeded, intent: intent, at: Timestamp(Date(timeIntervalSince1970: 0)))
        var goal = try await goal()
        goal.tasks[1].state = .skipped
        goal.tasks[1].skip = record
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID))
        let implement = try await taskJob(.implementTask, seed: "t2")
        try await skip(implement, attempt: 1)
        #expect(try await intake().processPending() == [.accepted(kind: "skipTask")])
        #expect(try await self.goal().tasks[1].skip == record)
        #expect(try await reread(implement).state == .canceled)
    }

    /// 飛ばせないもの: 人の対応を待っていないジョブ・試行が進んだジョブ・タスクでないジョブ・実装していない epic・ほかの理由で取り消したジョブ
    @Test func rejectsWhatCannotBeSkipped() async throws {
        try await started()
        let running = try await taskJob(.implementTask, state: .running, seed: "running")
        try await skip(running, attempt: 1)
        #expect(try await intake().processPending() == [.rejected(kind: "skipTask", reason: "ジョブは人の対応を待っていない（running）")])

        let stale = try await taskJob(.implementTask, attempts: 2, seed: "stale")
        try await skip(stale, attempt: 1, nonce: ULID(rawValue: "01JCN0NCE000000000000000S2")!)
        #expect(try await intake().processPending() == [.rejected(kind: "skipTask", reason: "試行の番号が今のジョブと違う（今は 2）")])

        let canceled = try await taskJob(.implementTask, state: .canceled, seed: "canceled")
        try await skip(canceled, attempt: 1, nonce: ULID(rawValue: "01JCN0NCE000000000000000S3")!)
        #expect(try await intake().processPending() == [.rejected(kind: "skipTask", reason: "ジョブは人の対応を待っていない（canceled）")])
        #expect(try await goal().tasks[1].state == .running)
    }

    /// 子 PR をマージした後に止まったレビュー（子ブランチを消せなかった）は飛ばさせない。「もう一度試す」で続きをする
    @Test func rejectsSkippingReviewThatAlreadyMerged() async throws {
        try await started()
        let head = String(repeating: "a", count: 40)
        let review = try await taskJob(.reviewTask, input: PullRequestInput(pullRequest: 41, head: head), seed: "review")
        let time = Timestamp(Self.now)
        let attempt = AttemptFile(
            job: review.id,
            number: 1,
            mac: Self.laptop,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .failed,
            failure: AttemptFailure(failureClass: .unexpected, message: "マージした子ブランチを消すことができない"),
            outputs: AttemptFile.Outputs(pullRequest: 41, commit: head, verdict: .merged)
        )
        try await put(attempt, at: StatePath.attempt(Self.repo, epic: Self.epicID, job: review.id, number: 1))
        try await skip(review, attempt: 1)
        let reason = "タスク t2 の子 PR はもうマージした。飛ばさずに「もう一度試す」で続きをする"
        #expect(try await intake().processPending() == [.rejected(kind: "skipTask", reason: reason)])
        #expect(try await goal().tasks[1].state == .running)
        #expect(try await reread(review).state == .waitingHuman)
    }

    /// 何も実装していないまま最後のタスクを飛ばすと、最終 PR に入れるものが無いので断る（epic ごとやめるなら「やめる」）
    @Test func rejectsSkippingThatLeavesNothingToMerge() async throws {
        try await started(t3: false)
        var goal = try await goal()
        goal.tasks[0].state = .skipped
        goal.tasks[0].skip = GoalFile.Skip(reason: .notNeeded, intent: TaskFlowTests.origin, at: Timestamp(Self.now))
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID))
        let implement = try await taskJob(.implementTask, seed: "t2")
        try await skip(implement, attempt: 1)
        let reason = "タスク t2 を飛ばすと、実装したタスクが 1 つも無く、最終 PR に入れるものが無い。epic ごとやめるなら「やめる」を選ぶ"
        #expect(try await intake().processPending() == [.rejected(kind: "skipTask", reason: reason)])
        #expect(try await self.goal().tasks[1].state == .running)
        #expect(goal.skippingLeavesNothing("t2"))
        // 実装したタスクがあるか、まだ進めるタスクが残っていれば飛ばせる
        goal.tasks[0].state = .done
        goal.tasks[0].skip = nil
        #expect(!goal.skippingLeavesNothing("t2"))
    }

    @Test(arguments: [EpicStage.finalizing, .reviewing])
    func rejectsJobsOutsideTaskStage(stage: EpicStage) async throws {
        try await started(stage: stage, taskState: .done)
        let verify = try await taskJob(.verifyBeforeFinal, seed: "verify")
        try await skip(verify, attempt: 1)
        let reason = "verifyBeforeFinal のジョブのタスクは飛ばせない（epic は \(stage.rawValue)）"
        #expect(try await intake().processPending() == [.rejected(kind: "skipTask", reason: reason)])
        #expect(try await reread(verify).state == .waitingHuman)
    }

    // MARK: - 文

    /// Claude に渡すゴールと Discussion の写しに、飛ばしたタスクと理由を書く
    @Test func goalTextsMarkSkippedTask() {
        var goal = TaskJobsTests.goal()
        goal.tasks[1].state = .skipped
        let at = Timestamp(Self.now)
        goal.tasks[1].skip = GoalFile.Skip(reason: .handledElsewhere, note: "Android で直す", intent: TaskFlowTests.origin, at: at)
        #expect(PromptText.goal(goal).contains("- t2: ランキングの画面を作る（一覧で出す） 前提: t1 【人が飛ばした。作らない（人が別にやる。Android で直す）】"))
        #expect(CopyText.goal(goal).contains("- 【飛ばした】t2. ランキングの画面を作る: 一覧で出す（前提: t1）（飛ばした理由: 人が別にやる。Android で直す）"))
    }
}

/// 最終 PR を出すときに、飛ばしたタスクの子 PR を閉じ、本文に飛ばしたタスクと理由を書く
struct SkippedTaskFinalTests {
    typealias Fixture = FinalJobFixture

    /// t2 を飛ばしたゴールにする（`pullRequest` は飛ばしたときに開いていた子 PR）
    private func skip(in fixture: Fixture, pullRequest: Int?) async throws {
        let record = GoalFile.Skip(
            reason: .handledElsewhere,
            note: "Android で直す",
            intent: TaskFlowTests.origin,
            at: Timestamp(TaskSkipTests.now),
            pullRequest: pullRequest
        )
        let path = StatePath.goal(Fixture.Tasks.repo, Fixture.Tasks.epic)
        _ = try await fixture.files.update(GoalFile.self, at: path, message: "skip") { goal in
            goal.tasks[1].state = .skipped
            goal.tasks[1].skip = record
            return true
        }
    }

    /// 作業ブランチ宛ての子 PR #30
    private static func childPull(state: PullRequest.State = .open, base: String = Fixture.branches.epic) -> PullRequest {
        PullRequest(number: 30, state: state, merged: false, head: (TaskJobFixture.branches.task, Fixture.head), baseRef: base)
    }

    private func open(_ fixture: Fixture) async throws -> JobResult {
        try await OpenFinalPullRequestRunner(environment: try fixture.environment()).execute(fixture.job(.openFinalPullRequest, "01"))
    }

    @Test func closesSkippedChildPullRequestAndListsSkippedTask() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        try await skip(in: fixture, pullRequest: 30)
        fixture.pulls.update { $0.pulls[30] = Self.childPull() }
        let result = try await open(fixture)
        #expect(result.failure == nil)
        #expect(result.outputs?.pullRequest == 41)
        #expect(fixture.pulls.current.stateChanges.map(\.number) == [30])
        #expect(fixture.pulls.current.pulls[30]?.state == .closed)
        let comment = try #require(fixture.pulls.current.comments.first)
        #expect(comment.number == 30)
        #expect(comment.body.contains("タスク t2 を人が飛ばした（人が別にやる。Android で直す）ので、マージせずに閉じました"))
        #expect(ProtocolMarker.parse(comment.body)?.value["type"]?.stringValue == "skippedTask")
        let body = try #require(fixture.pulls.current.drafts.first?.body)
        #expect(body.contains("- t2: ランキングの画面を作る（飛ばした）"))
        #expect(body.contains("## 飛ばしたタスク"))
        #expect(body.contains("- t2: ランキングの画面を作る — 人が別にやる。Android で直す（子 PR #30 はマージせずに閉じる）"))
    }

    /// 閉じた・ほかのブランチ宛ての子 PR には触れない
    @Test(arguments: [childPull(state: .closed), childPull(base: "develop")])
    func leavesOtherChildPullRequestsAlone(pull: PullRequest) async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        try await skip(in: fixture, pullRequest: 30)
        fixture.pulls.update { $0.pulls[30] = pull }
        let result = try await open(fixture)
        #expect(result.failure == nil)
        #expect(result.outputs?.pullRequest == 41)
        #expect(fixture.pulls.current.stateChanges.isEmpty)
        #expect(fixture.pulls.current.comments.isEmpty)
    }

    /// 飛ばした後に元の試行が作った子 PR（記録に無い番号）も閉じる。コメントを書けなくても止めない
    @Test func closesEveryOpenPullRequestFromSkippedBranchEvenIfCommentFails() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        try await skip(in: fixture, pullRequest: nil)
        fixture.pulls.update { state in
            state.pulls[30] = Self.childPull()
            var later = Self.childPull()
            later.number = 31
            state.pulls[31] = later
            state.commentFailures = [.forbidden(message: nil)]
        }
        let result = try await open(fixture)
        #expect(result.failure == nil)
        #expect(fixture.pulls.current.stateChanges.map(\.number) == [30, 31])
        #expect(fixture.pulls.current.comments.map(\.number) == [31])
    }

    /// 閉じられなければ試行の失敗にする（作業ブランチを消しても GitHub は開いた子 PR を閉じず、向き先を base に変えるので、開いたまま残さない）
    @Test func failsAttemptWhenChildPullRequestCannotBeClosed() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        try await skip(in: fixture, pullRequest: 30)
        fixture.pulls.update { state in
            state.pulls[30] = Self.childPull()
            state.closeFailures = [(false, .forbidden(message: nil))]
        }
        let result = try await open(fixture)
        #expect(result.failure?.message.contains("飛ばしたタスクの子 PR を閉じる") == true)
        #expect(result.outputs?.pullRequest == 41)
        #expect(fixture.pulls.current.pulls[30]?.state == .open)
    }

    /// GitHub の上限なら試行の失敗にする（最終 PR は出したので、やり直しで同じ PR を使い、子 PR を閉じる続きをする）
    @Test func rateLimitFailsAttemptKeepingFinalPullRequest() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        try await skip(in: fixture, pullRequest: 30)
        fixture.pulls.update { state in
            state.pulls[30] = Self.childPull()
            state.closeFailures = [(false, .rateLimited(retryAfter: .seconds(60)))]
        }
        let result = try await open(fixture)
        #expect(result.failure?.failureClass == .githubOutage)
        #expect(result.outputs?.pullRequest == 41)
        let retried = try await open(fixture)
        #expect(retried.failure == nil)
        #expect(retried.outputs?.pullRequest == 41)
        #expect(fixture.pulls.current.pulls[30]?.state == .closed)
    }
}

/// 子 PR のレビュー: 人がタスクを飛ばした後はマージしない。マージした後に子ブランチを消せなければ、マージしたことを残す
struct SkippedTaskReviewTests {
    typealias Fixture = TaskJobFixture
    static let input = PullRequestInput(pullRequest: 41, head: sha("1"))

    private func fixture() async throws -> Fixture {
        let fixture = Fixture(reviews: [ReviewTaskRunnerTests.noFindings])
        try await fixture.prepare()
        fixture.pulls.update { state in
            state.pulls[41] = Fixture.openPull(head: sha("1"))
            state.checks = [CheckSummary(verdict: .passed)]
        }
        return fixture
    }

    private func review(_ fixture: Fixture) async throws -> JobResult {
        let runner = ReviewTaskRunner(environment: try fixture.environment(FakeTaskRunner([])))
        return try await runner.execute(fixture.job(.reviewTask, "03", input: Self.input.jobInput))
    }

    @Test func doesNotMergeChildPullRequestOfSkippedTask() async throws {
        let fixture = try await fixture()
        let record = GoalFile.Skip(reason: .handledElsewhere, intent: TaskFlowTests.origin, at: Timestamp(TaskSkipTests.now))
        try await fixture.files.update(GoalFile.self, at: StatePath.goal(Fixture.repo, Fixture.epic), message: "skip") { goal in
            goal.tasks[1].state = .skipped
            goal.tasks[1].skip = record
            return true
        }
        let result = try await review(fixture)
        #expect(result.failure?.message == "タスク t2 は人が飛ばしたので、子 PR をマージしない")
        #expect(fixture.pulls.current.merges.isEmpty)
    }

    @Test func keepsMergedVerdictWhenChildBranchCannotBeDeleted() async throws {
        let fixture = try await fixture()
        fixture.pulls.update { $0.deleteError = .forbidden(message: nil) }
        let result = try await review(fixture)
        #expect(result.failure != nil)
        #expect(result.outputs?.verdict == .merged)
        #expect(fixture.pulls.current.merges.map(\.number) == [41])
    }

    @Test func keepsMergedVerdictWhenMergedPullRequestCannotBeReread() async throws {
        let fixture = try await fixture()
        // マージの後の読み直し（3 回目の読み）だけを失敗させる
        let reads = OSAllocatedCounter()
        fixture.pulls.update { state in
            state.onRead = { pull in
                if reads.increment() == 3 { pull.number = 0 }
            }
        }
        let result = try await review(fixture)
        #expect(result.failure != nil)
        #expect(result.outputs?.verdict == .merged)
    }
}
