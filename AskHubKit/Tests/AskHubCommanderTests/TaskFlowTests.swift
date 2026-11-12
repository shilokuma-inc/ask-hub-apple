@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 司令塔が、ジョブの結果からタスクを進めるジョブを作る（作業場所の用意 → 実装 → レビュー →（直し → レビュー）→ 次のタスク）
struct TaskFlowTests {
    static let repo = EpicHandlersTests.repo
    static let laptop = EpicHandlersTests.laptop
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let origin = IntentReference(
        keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
        nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!
    )
    static let report = TaskOutputReport(
        summary: "集計を作った",
        decisions: [.init(what: "見出しを短くした", why: "iPhone の幅に収める", alternatives: ["2 行にする"])]
    )

    let store = InMemoryStateStore()
    var context: CommanderContext { CommanderContext(store: store, mac: EpicHandlersTests.commander) { Self.now } }
    var flow: TaskFlow { TaskFlow(context: context) }

    static func sha(_ character: Character) -> String {
        String(repeating: character, count: 40)
    }

    private func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    private func read<File: StateFile>(_ type: File.Type, at path: String) async throws -> File? {
        try await store.data(at: path).map { try StateFileCoder.decode(File.self, from: $0) }
    }

    private func jobs() async throws -> [JobFile] {
        var jobs: [JobFile] = []
        for entry in try await store.list(StatePath.jobs(Self.repo, epic: Self.epicID)) ?? [] {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }

    private func epic() async throws -> EpicFile {
        try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, Self.epicID)))
    }

    private func states() async throws -> [TaskState] {
        try #require(try await read(GoalFile.self, at: StatePath.goal(Self.repo, Self.epicID))).tasks.map(\.state)
    }

    /// 今の状態の jobs で 1 回進める（司令塔の 1 周で、ジョブの状態を決めた後にすること）
    private func advance(jobs given: [JobFile]? = nil) async throws -> TaskFlow.Advanced {
        var jobs = given ?? []
        if given == nil { jobs = try await self.jobs() }
        return await flow.advance(epics: [try await epic()], jobs: jobs)
    }

    /// 開始した epic（作業ブランチはまだ無い）と、ゴール（t1 → t2）と、成功した作業場所の用意
    @discardableResult
    private func started(prepared: Bool = true) async throws -> JobFile {
        let time = Timestamp(Self.now)
        let epic = EpicFile(
            id: Self.epicID,
            repo: Self.repo,
            title: "ランキング",
            stage: .running,
            mac: Self.laptop,
            goalVersion: 1,
            createdAt: time,
            updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, Self.epicID))
        let tasks: [GoalFile.Task] = [.init(id: "t1", title: "集計を作る"), .init(id: "t2", title: "画面を作る", dependsOn: ["t1"])]
        try await put(GoalFile(version: 1, summary: "ランキングを作る", doneWhen: ["…"], tasks: tasks), at: StatePath.goal(Self.repo, Self.epicID))
        let spec = JobSpec(kind: .prepareWorkspace, mac: Self.laptop, needs: .init(claude: false, build: false))
        let prepare = context.job(spec, for: epic, origin: Self.origin, seed: "")
        try await put(prepare, at: StatePath.job(Self.repo, epic: Self.epicID, job: prepare.id))
        guard prepared else { return prepare }
        return try await succeed(prepare, outputs: .init(commit: Self.sha("0"), branch: "askhub/\(Self.epicID)"))
    }

    /// ジョブを成功にし、成功した試行を書く（司令塔が試行を読んでジョブの状態を決めた後）
    @discardableResult
    private func succeed(_ job: JobFile, outputs: AttemptFile.Outputs) async throws -> JobFile {
        var job = job
        job.attempts += 1
        job.state = .succeeded
        let time = Timestamp(Self.now)
        let attempt = AttemptFile(
            job: job.id,
            number: job.attempts,
            mac: Self.laptop,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            outputs: outputs
        )
        try await put(attempt, at: StatePath.attempt(Self.repo, epic: Self.epicID, job: job.id, number: job.attempts))
        try await put(job, at: StatePath.job(Self.repo, epic: Self.epicID, job: job.id))
        return job
    }

    // MARK: - 成功

    @Test func runsTasksInGoalOrderUntilAllMerged() async throws {
        let prepare = try await started()
        var step = try await advance()
        #expect(try await epic().branch == "askhub/\(Self.epicID)")
        let implement = try #require(step.created.first)
        #expect(step.created.count == 1)
        #expect(implement.kind == .implementTask)
        #expect(implement.task == "t1")
        #expect(implement.assignedMac == Self.laptop)
        #expect(implement.state == .assigned)
        #expect(implement.dependsOn == [prepare.id])
        #expect(implement.needs == .init(claude: true, build: true))
        #expect(implement.origin == Self.origin)
        #expect(try await states() == [.running, .pending])

        // 実装が成功: 仮決めを足し（区分は決めない）、push した head でレビューを作る
        try await succeed(implement, outputs: .init(pullRequest: 41, commit: Self.sha("a"), branch: "askhub/E-t1", report: Self.report))
        step = try await advance()
        let review = try #require(step.created.first)
        #expect(review.kind == .reviewTask)
        #expect(review.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: 41, head: Self.sha("a")))
        #expect(review.dependsOn == [implement.id])
        #expect(review.needs == .init(claude: true, build: false))
        let decisions = try #require(try await read(DecisionsFile.self, at: StatePath.decisions(Self.repo, Self.epicID)))
        let decision = DecisionsFile.Item(
            id: "d1", task: "t1", pullRequest: 41, what: "見出しを短くした", why: "iPhone の幅に収める", alternatives: ["2 行にする"]
        )
        #expect(decisions.items == [decision])

        // マージした: タスクを done にし、依存が済んだ次のタスクへ
        try await succeed(review, outputs: .init(commit: Self.sha("b"), verdict: .merged))
        step = try await advance()
        let next = try #require(step.created.first)
        #expect(next.kind == .implementTask)
        #expect(next.task == "t2")
        #expect(next.dependsOn == [prepare.id])
        #expect(try await states() == [.done, .running])

        try await succeed(next, outputs: .init(pullRequest: 42, commit: Self.sha("c")))
        let last = try #require(try await advance().created.first)
        try await succeed(last, outputs: .init(commit: Self.sha("d"), verdict: .merged))
        step = try await advance()
        // すべて済んだら、epic を最終 PR の段取り（finalizing）にして、最終 PR の前の検証を作る（続きは FinalFlowTests）
        #expect(step.created.map(\.kind) == [.verifyBeforeFinal])
        #expect(step.notes.first?.contains("すべて済んだ") == true)
        #expect(try await states() == [.done, .done])
        #expect(try await epic().stage == .finalizing)
        #expect(try await advance() == TaskFlow.Advanced())
    }

    @Test func waitsUntilWorkspaceIsPreparedAndEpicIsRunning() async throws {
        let prepare = try await started(prepared: false)
        #expect(try await advance() == TaskFlow.Advanced())
        #expect(try await states() == [.pending, .pending])

        // 作業ブランチが結果に無ければ、進めずに知らせる
        try await succeed(prepare, outputs: .init(commit: Self.sha("0")))
        let step = try await advance()
        #expect(step.created.isEmpty)
        #expect(step.notes.first?.contains("作業ブランチが無い") == true)

        var stopped = try await epic()
        stopped.stage = .merged
        try await put(stopped, at: StatePath.epic(Self.repo, Self.epicID))
        #expect(await flow.advance(epics: [stopped], jobs: try await jobs()) == TaskFlow.Advanced())
    }

    // MARK: - 直し

    @Test func fixesUpToLimitThenHandsOverToHuman() async throws {
        try await started()
        let implement = try #require(try await advance().created.first)
        try await succeed(implement, outputs: .init(pullRequest: 41, commit: Self.sha("a")))
        var review = try #require(try await advance().created.first)
        for round in 1...3 {
            let verdict: ReviewVerdict = round == 2 ? .fixReview : .fixCI
            let seen = try #require(review.input(as: PullRequestInput.self))
            try await succeed(review, outputs: .init(commit: seen.head, verdict: verdict, findings: "build / build が落ちた"))
            let fix = try #require(try await advance().created.first)
            #expect(fix.kind == .fixTask)
            #expect(fix.state == .assigned)
            #expect(fix.dependsOn == [review.id])
            let reason: FixTaskInput.Reason = verdict == .fixCI ? .ci : .review
            #expect(fix.input(as: FixTaskInput.self) == FixTaskInput(pullRequest: 41, head: seen.head, reason: reason))
            // 直した head で、レビューを作り直す
            let head = Self.sha(Character(String(round)))
            try await succeed(fix, outputs: .init(pullRequest: 41, commit: head, report: TaskOutputReport(summary: "直した")))
            review = try #require(try await advance().created.first)
            #expect(review.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: 41, head: head))
            #expect(review.dependsOn == [fix.id])
        }
        // 4 回目の直しは、作るが動かさずに人に渡す（人が「やり直す」を送れば動く）
        try await succeed(review, outputs: .init(commit: Self.sha("3"), verdict: .fixCI, findings: "まだ落ちる"))
        let step = try await advance()
        let handedOver = try #require(step.created.first)
        #expect(handedOver.kind == .fixTask)
        #expect(handedOver.state == .waitingHuman)
        // 試行の前に渡すので、人の「やり直す」は試行の番号 0 で届く（JobHandlersTests）
        #expect(handedOver.attempts == 0)
        #expect(step.notes.first?.contains("人に渡した") == true)
        #expect(try await jobs().filter { $0.kind == .fixTask }.count == 4)
        // 人の対応を待つ間は、何もしない
        #expect(try await advance() == TaskFlow.Advanced())
        #expect(try await states() == [.running, .pending])
    }

    // MARK: - やり直し

    @Test func redoingCreatesNoDuplicateJobsOrDecisions() async throws {
        try await started()
        // 実装を作った後、タスクを running にする前に止まった: 次の周で同じ id のジョブを作ろうとするだけ
        let implement = try #require(try await advance().created.first)
        var goal = try #require(try await read(GoalFile.self, at: StatePath.goal(Self.repo, Self.epicID)))
        goal.tasks[0].state = .pending
        try await put(goal, at: StatePath.goal(Self.repo, Self.epicID))
        #expect(try await advance().created.map(\.id) == [implement.id])
        #expect(try await jobs().filter { $0.kind == .implementTask }.count == 1)
        #expect(try await states() == [.running, .pending])

        // 実装の結果を当てて、レビューを作る前に止まった（同じ見直しの結果で 2 回進める）: 仮決めもレビューも 1 つ
        try await succeed(implement, outputs: .init(pullRequest: 41, commit: Self.sha("a"), report: Self.report))
        let beforeReview = try await jobs()
        let first = try await advance(jobs: beforeReview)
        let second = try await advance(jobs: beforeReview)
        #expect(first.created.map(\.id) == second.created.map(\.id))
        #expect(try await jobs().filter { $0.kind == .reviewTask }.count == 1)
        #expect(try await read(DecisionsFile.self, at: StatePath.decisions(Self.repo, Self.epicID))?.items.count == 1)

        // 直しも同じ
        let review = try #require(first.created.first)
        try await succeed(review, outputs: .init(commit: Self.sha("a"), verdict: .fixCI, findings: "落ちた"))
        let beforeFix = try await jobs()
        let fix = try await advance(jobs: beforeFix)
        #expect(try await advance(jobs: beforeFix).created.map(\.id) == fix.created.map(\.id))
        #expect(try await jobs().filter { $0.kind == .fixTask }.count == 1)
    }
}
