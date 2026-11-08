@testable import AskHubClaude
@testable import AskHubCommander
import AskHubJobs
import AskHubProtocol
import Foundation
import Testing

/// 実装の途中の質問で止める・答えで再開する（ワーカー。`docs/renewal/flows.md` の「実装の途中の質問」）
struct TaskQuestionRunnerTests {
    typealias Fixture = TaskJobFixture
    static let keyID = KeyID(rawValue: String(repeating: "k", count: 43))!
    static let answer = QuestionsFile.Answer(
        choice: "名前順",
        note: "同点は ID 順",
        intent: IntentReference(keyId: keyID, nonce: ULID(rawValue: "01JCJ0D0000000000000000001")!),
        at: Timestamp(Fixture.start.addingTimeInterval(600))
    )
    static let askedClaude = AttemptFile.Claude(model: "claude-opus-5-5", session: "s-ask", estimatedCostUsd: 0.2)

    /// Claude が人に聞いて止まる
    static func asking() -> TaskReply {
        let session = ClaudeSession(id: "s-ask", model: "claude-opus-5-5", estimatedCostUsd: 0.2, calls: 1)
        let report = TaskReport(outcome: .needsQuestion, summary: "並びを決めてほしい", question: TaskJobsTests.question)
        return .reported(report, TaskRun(session: session))
    }

    /// 質問した試行（`outputs.report.question`）と、質問の一覧（開始前の q1・ほかのタスクの q2・答えた q3）を置く
    static func asked(
        _ fixture: Fixture,
        job: JobFile,
        task: String?,
        outputs: AttemptFile.Outputs,
        state: QuestionState = .answered,
        mac: MacName = Fixture.mac,
        claude: AttemptFile.Claude? = askedClaude
    ) async throws {
        var outputs = outputs
        outputs.report = TaskOutputReport(summary: "並びを決めてほしい", question: .init(
            title: TaskJobsTests.question.title,
            why: TaskJobsTests.question.why,
            options: TaskJobsTests.question.options,
            recommended: TaskJobsTests.question.recommended,
            reason: TaskJobsTests.question.reason
        ))
        try await fixture.record(job, outputs: outputs, claude: claude, mac: mac)
        let other = ULID(rawValue: "01JCJ0B000000000000000000Z")!
        let questions = QuestionsFile(questions: [
            question("q1", title: "上位を何件出すか", round: 1, state: .answered),
            question("q2", title: "取得の間隔", round: 2, state: .answered, job: other, task: "t1"),
            question("q3", title: TaskJobsTests.question.title, round: 3, state: state, job: job.id, task: task)
        ])
        try await fixture.files.create(questions, at: StatePath.questions(Fixture.repo, Fixture.epic), message: "questions")
    }

    static func question(
        _ id: String,
        title: String,
        round: Int,
        state: QuestionState,
        job: ULID? = nil,
        task: String? = nil
    ) -> QuestionsFile.Question {
        QuestionsFile.Question(
            id: id,
            title: title,
            why: "…",
            options: TaskJobsTests.question.options,
            recommended: "名前順",
            reason: "探しやすい",
            round: round,
            state: state,
            answer: state == .answered ? answer : nil,
            job: job,
            task: task
        )
    }

    /// 答えで再開するジョブ
    static func resumption(
        _ fixture: Fixture,
        _ kind: JobKind,
        _ id: String,
        input: [String: JSONValue],
        after asking: JobFile
    ) -> JobFile {
        var job = fixture.job(kind, id, input: input)
        job.dependsOn = [asking.id]
        return job
    }

    // MARK: - 実装

    @Test func questionKeepsChangesWithoutCommitOrChildPullRequest() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let runner = ImplementTaskRunnerTests.editing(fixture.git, [Self.asking()])
        let job = fixture.job(.implementTask, "02")
        try await fixture.files.create(job, at: StatePath.job(Fixture.repo, epic: Fixture.epic, job: job.id), message: "job")

        // 試行は JobWorker が書く（質問で終えた試行が、状態リポジトリの決まりに合うことも確かめる）
        let worker = JobWorker(
            runner: ImplementTaskRunner(environment: try fixture.environment(runner)),
            recorder: AttemptRecorder(files: fixture.context.files, mac: Fixture.mac) { fixture.sleeper.now }
        )
        let attempt = try #require(try await worker.perform(job))
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.failure == nil)
        #expect(attempt.outputs?.report?.question?.recommended == "名前順")
        #expect(attempt.outputs?.branch == Fixture.branches.task)
        #expect(attempt.outputs?.pullRequest == nil)
        #expect(attempt.outputs?.commit == nil)
        #expect(attempt.claude?.session == "s-ask")
        // 手元の変更を残し、commit・push・子 PR をしない
        #expect(fixture.git.current.dirty)
        #expect(!fixture.git.current.calls.contains("commitAndPush"))
        #expect(fixture.pulls.current.drafts.isEmpty)
    }

    @Test func resumesAskingConversationInKeptWorkspace() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let asking = fixture.job(.implementTask, "02")
        try await Self.asked(fixture, job: asking, task: "t2", outputs: .init(branch: Fixture.branches.task))
        // 質問したときの作業場所（子ブランチと手元の変更）が残っている
        fixture.git.update {
            $0.workspace = (Fixture.branches.task, Fixture.base)
            $0.dirty = true
        }
        let runner = FakeTaskRunner([FakeTaskRunner.done("並びを名前順にした。", session: "s-ask")])
        let job = Self.resumption(fixture, .implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput, after: asking)
        let result = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(job)

        #expect(result.failure == nil)
        #expect(result.outputs?.pullRequest == 41)
        #expect(result.outputs?.commit == sha("1"))
        // 取り出し直さない（手元の変更を捨てない）
        #expect(fixture.git.current.calls.contains("reuseTask \(Fixture.branches.task)"))
        #expect(!fixture.git.current.calls.contains("checkOutTask \(Fixture.branches.task)"))
        // 質問した会話を再開し、人の答え（選んだ選択肢と補足）を渡す
        let call = try #require(runner.calls.first)
        #expect(call.kind == .implementTask)
        #expect(call.resume == "s-ask")
        #expect(call.prompt.contains("あなたの質問（q3）に答えました"))
        #expect(call.prompt.contains("人の答え: 「名前順」を選んだ\n補足: 同点は ID 順"))
        #expect(call.prompt.contains("<answer>"))
        #expect(call.directory == FakeTaskGit.directory)
    }

    @Test func redoesInNewConversationWhenWorkspaceIsGone() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let asking = fixture.job(.implementTask, "02")
        try await Self.asked(fixture, job: asking, task: "t2", outputs: .init(branch: Fixture.branches.task))
        let runner = ImplementTaskRunnerTests.editing(fixture.git, [FakeTaskRunner.done("並びを名前順にした。", session: "s-new")])
        let job = Self.resumption(fixture, .implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput, after: asking)
        let result = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(job)

        #expect(result.failure == nil)
        #expect(result.outputs?.pullRequest == 41)
        #expect(fixture.git.current.calls.contains("checkOutTask \(Fixture.branches.task)"))
        // 新しい会話で、元の依頼に決まったことを足し、変更を初めからやり直させる
        let call = try #require(runner.calls.first)
        #expect(call.resume == nil)
        #expect(call.prompt.contains("次のタスクを 1 つ実装してください"))
        #expect(call.prompt.contains("初めから変更をやり直してください"))
        #expect(call.prompt.contains("id: q3"))
        #expect(call.prompt.contains("補足: 同点は ID 順"))
        // ほかのタスク（t1）の途中の質問は渡さない
        #expect(!call.prompt.contains("取得の間隔"))
    }

    @Test func continuesKeptChangesInNewConversationWhenResumeFails() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let asking = fixture.job(.implementTask, "02")
        try await Self.asked(fixture, job: asking, task: "t2", outputs: .init(branch: Fixture.branches.task))
        fixture.git.update {
            $0.workspace = (Fixture.branches.task, Fixture.base)
            $0.dirty = true
        }
        // `--resume` が失敗した（会話が残っていない）。Claude の結果を何も受け取れていない
        let lost = TaskReply.failed(AttemptFailure(failureClass: .unexpected, message: "No conversation found"), TaskRun())
        let runner = FakeTaskRunner([lost, FakeTaskRunner.done("並びを名前順にした。", session: "s-new")])
        let job = Self.resumption(fixture, .implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput, after: asking)
        let result = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(job)

        #expect(result.failure == nil)
        #expect(result.claude?.session == "s-new")
        #expect(!fixture.git.current.calls.contains("checkOutTask \(Fixture.branches.task)"))
        // 同じ再開を失敗し続けないよう、作業場所はそのまま、新しい会話で途中の変更から続けさせる
        #expect(runner.calls.map(\.resume) == ["s-ask", nil])
        let call = try #require(runner.calls.last)
        #expect(call.prompt.contains("次のタスクを 1 つ実装してください"))
        #expect(call.prompt.contains("途中の変更から続けてください"))
        #expect(call.prompt.contains("補足: 同点は ID 順"))
    }

    @Test func continuesKeptChangesInNewConversationWithoutRecordedConversation() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let asking = fixture.job(.implementTask, "02")
        // 質問した試行に会話の記録が無い（会話が残っていない）
        let claude = AttemptFile.Claude(model: "claude-opus-5-5", session: nil, estimatedCostUsd: 0.2)
        try await Self.asked(fixture, job: asking, task: "t2", outputs: .init(branch: Fixture.branches.task), claude: claude)
        fixture.git.update {
            $0.workspace = (Fixture.branches.task, Fixture.base)
            $0.dirty = true
        }
        let runner = FakeTaskRunner([FakeTaskRunner.done("並びを名前順にした。", session: "s-new")])
        let job = Self.resumption(fixture, .implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput, after: asking)
        let result = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(job)

        // 再開を試さずに、作業場所はそのまま、新しい会話で途中の変更から続けさせる
        #expect(result.failure == nil)
        #expect(!fixture.git.current.calls.contains("checkOutTask \(Fixture.branches.task)"))
        #expect(runner.calls.map(\.resume) == [nil])
        #expect(runner.calls.first?.prompt.contains("途中の変更から続けてください") == true)
        #expect(runner.calls.first?.prompt.contains("「名前順」を選んだ") == true)
    }

    @Test func keepsResumingWhenFailureIsNotAboutConversation() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let asking = fixture.job(.implementTask, "02")
        try await Self.asked(fixture, job: asking, task: "t2", outputs: .init(branch: Fixture.branches.task))
        fixture.git.update { $0.workspace = (Fixture.branches.task, Fixture.base) }
        // 利用上限は、会話を再開できないのではない（次の試行で、また同じ会話を再開する）
        let limited = TaskReply.failed(AttemptFailure(failureClass: .usageLimit, message: "Claude の利用上限に達した"), TaskRun())
        let runner = FakeTaskRunner([limited])
        let job = Self.resumption(fixture, .implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput, after: asking)
        let result = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(job)
        #expect(result.failure?.failureClass == .usageLimit)
        #expect(runner.calls.map(\.resume) == ["s-ask"])
    }

    @Test func redoesWhenAskingConversationIsOnAnotherMac() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let asking = fixture.job(.implementTask, "02")
        let other = MacName(rawValue: "mac-mini")!
        try await Self.asked(fixture, job: asking, task: "t2", outputs: .init(branch: Fixture.branches.task), mac: other)
        fixture.git.update { $0.workspace = (Fixture.branches.task, Fixture.base) }
        let runner = ImplementTaskRunnerTests.editing(fixture.git, [FakeTaskRunner.done()])
        let job = Self.resumption(fixture, .implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput, after: asking)
        let result = try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(job)

        // 会話はほかの Mac にあるので、この Mac の作業場所は使わずに取り出し直す
        #expect(result.failure == nil)
        #expect(!fixture.git.current.calls.contains { $0.hasPrefix("reuseTask") })
        #expect(runner.calls.first?.resume == nil)
    }

    @Test func refusesResumeWithoutAnswerOrForOtherJob() async throws {
        let unanswered = Fixture()
        try await unanswered.prepare()
        let asking = unanswered.job(.implementTask, "02")
        try await Self.asked(unanswered, job: asking, task: "t2", outputs: .init(), state: .open)
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let job = Self.resumption(unanswered, .implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput, after: asking)
        let noAnswer = try await ImplementTaskRunner(environment: try unanswered.environment(runner)).execute(job)
        #expect(noAnswer.failure?.message.contains("答えが無い") == true)

        // 質問したジョブが、このジョブの前のジョブでない
        let other = Fixture()
        try await other.prepare()
        let asked = other.job(.implementTask, "02")
        try await Self.asked(other, job: asked, task: "t2", outputs: .init())
        var unrelated = other.job(.implementTask, "04", input: ImplementTaskInput(question: "q3").jobInput)
        unrelated.dependsOn = []
        let wrongJob = try await ImplementTaskRunner(environment: try other.environment(runner)).execute(unrelated)
        #expect(wrongJob.failure?.message.contains("実装の途中の質問でない") == true)

        // 開始する前の質問では再開しない
        let planning = Self.resumption(other, .implementTask, "05", input: ImplementTaskInput(question: "q1").jobInput, after: asked)
        let beforeStart = try await ImplementTaskRunner(environment: try other.environment(runner)).execute(planning)
        #expect(beforeStart.failure?.message.contains("実装の途中の質問でない") == true)
        #expect(runner.calls.isEmpty)
    }
}

// MARK: - 子 PR の直し

extension TaskQuestionRunnerTests {
    /// 子 PR #41 と、直す判定を書いたレビュー、質問した直しを置く
    func fixFixture(answered: Bool = true) async throws -> (Fixture, asking: JobFile) {
        let fixture = try await FixTaskRunnerTests().fixture()
        let input = FixTaskInput(pullRequest: 41, head: FixTaskRunnerTests.head, reason: .ci)
        let review = PullRequestInput(pullRequest: 41, head: FixTaskRunnerTests.head)
        let ci = AttemptFile.Outputs(
            pullRequest: 41, commit: FixTaskRunnerTests.head, verdict: .fixCI, findings: FixTaskRunnerTests.ciFindings
        )
        try await fixture.record(fixture.job(.reviewTask, "06", input: review.jobInput), outputs: ci, endedAt: 90)
        let asking = fixture.job(.fixTask, "07", input: input.jobInput)
        try await Self.asked(fixture, job: asking, task: "t2", outputs: .init(pullRequest: 41, branch: Fixture.branches.task))
        return (fixture, asking)
    }

    @Test func fixQuestionKeepsChangesWithoutPushing() async throws {
        let fixture = try await FixTaskRunnerTests().fixture()
        let runner = ImplementTaskRunnerTests.editing(fixture.git, [Self.asking()])
        let input = FixTaskInput(pullRequest: 41, head: FixTaskRunnerTests.head, reason: .review)
        let job = fixture.job(.fixTask, "05", input: input.jobInput)
        let result = try await FixTaskRunner(environment: try fixture.environment(runner)).execute(job)
        #expect(result.failure == nil)
        #expect(result.outputs?.report?.question?.title == "ランキングの並び")
        #expect(result.outputs?.pullRequest == 41)
        #expect(result.outputs?.commit == nil)
        #expect(result.claude?.session == "s-ask")
        #expect(fixture.git.current.dirty)
        #expect(fixture.git.current.commits.isEmpty)
    }

    @Test func fixResumesAskingConversationAndKeepsFailingCheck() async throws {
        let (fixture, asking) = try await fixFixture()
        fixture.git.update {
            $0.workspace = (Fixture.branches.task, FixTaskRunnerTests.head)
            $0.dirty = true
        }
        let runner = FakeTaskRunner([FakeTaskRunner.done("名前順で比べるようにした。", session: "s-ask")])
        let input = FixTaskInput(pullRequest: 41, head: FixTaskRunnerTests.head, reason: .ci, question: "q3")
        let job = Self.resumption(fixture, .fixTask, "08", input: input.jobInput, after: asking)
        let result = try await FixTaskRunner(environment: try fixture.environment(runner)).execute(job)

        #expect(result.failure == nil)
        #expect(result.outputs?.commit == sha("1"))
        #expect(!fixture.git.current.calls.contains("checkOutTask \(Fixture.branches.task)"))
        let call = try #require(runner.calls.first)
        #expect(call.kind == .fixTask)
        #expect(call.resume == "s-ask")
        #expect(call.prompt.contains("「名前順」を選んだ"))
        // CI の直しの続きなので、軽いテスト以上が通るまで done にさせない
        #expect(call.failingAtStart == .testLight)
    }

    @Test func fixResumeRefusesBranchMovedByOtherChanges() async throws {
        let (fixture, asking) = try await fixFixture()
        // 答えを待つ間に、ほかで子ブランチが進んだ
        let moved = sha("9")
        fixture.git.update {
            $0.remote[Fixture.branches.task] = moved
            $0.ancestors = ["\(FixTaskRunnerTests.head)..\(moved)"]
            $0.history = ["\(FixTaskRunnerTests.head)..\(moved)": ["ほかの人の変更"]]
        }
        fixture.pulls.update { $0.pulls[41] = Fixture.openPull(head: moved) }
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let input = FixTaskInput(pullRequest: 41, head: FixTaskRunnerTests.head, reason: .ci, question: "q3")
        let job = Self.resumption(fixture, .fixTask, "08", input: input.jobInput, after: asking)
        let refused = try await FixTaskRunner(environment: try fixture.environment(runner)).execute(job)
        // 人の答えを渡さないまま、進んだ head を直した結果にしない
        #expect(refused.failure?.failureClass == .unexpected)
        #expect(refused.failure?.message.contains("ほかの変更で進んだ") == true)
        #expect(runner.calls.isEmpty)

        // この直しの前の試行が push した後に落ちたのなら、その先頭を結果にする（直させ直さない）
        let trailer = FixFinalPullRequestRunner.trailer(of: job.id)
        fixture.git.update { $0.history = ["\(FixTaskRunnerTests.head)..\(moved)": ["一覧を直す\n\n\(trailer)"]] }
        let retried = try await FixTaskRunner(environment: try fixture.environment(runner)).execute(job)
        #expect(retried.failure == nil)
        #expect(retried.outputs?.commit == moved)
        #expect(runner.calls.isEmpty)
    }

    @Test func fixRedoesInNewConversationWithGoalAndFindings() async throws {
        let (fixture, asking) = try await fixFixture()
        let runner = ImplementTaskRunnerTests.editing(fixture.git, [FakeTaskRunner.done("名前順で比べるようにした。", session: "s-new")])
        let input = FixTaskInput(pullRequest: 41, head: FixTaskRunnerTests.head, reason: .ci, question: "q3")
        let job = Self.resumption(fixture, .fixTask, "08", input: input.jobInput, after: asking)
        let result = try await FixTaskRunner(environment: try fixture.environment(runner)).execute(job)

        #expect(result.failure == nil)
        let call = try #require(runner.calls.first)
        // 新しい会話（実装の会話も質問した会話も続けない）。ゴールとタスク、CI のログ、決まったことを渡す
        #expect(call.resume == nil)
        #expect(call.prompt.contains("あなたは、次のゴールのタスク t2 を実装して子 PR を出しました"))
        #expect(call.prompt.contains("<goal>"))
        #expect(call.prompt.contains(FixTaskRunnerTests.ciFindings))
        #expect(call.prompt.contains("初めから変更をやり直してください"))
        #expect(call.prompt.contains("補足: 同点は ID 順"))
        #expect(call.failingAtStart == .testLight)
        // どのジョブの直しかをコミットに書く（前の試行が push した後に落ちたかを見分ける）
        #expect(fixture.git.current.commits.first?.hasSuffix(FixFinalPullRequestRunner.trailer(of: job.id)) == true)
    }
}

// MARK: - 最終 PR の直し

extension TaskQuestionRunnerTests {
    typealias Final = FinalJobFixture

    /// 最終 PR #512 と、直す判定のレビュー、質問した直し（`0F`）を置く
    func finalFixture(reason: FixTaskInput.Reason, verdict: ReviewVerdict) async throws -> (Final, asking: JobFile) {
        let fixture = try await FixMergeFinalPullRequestRunnerTests().fixture()
        let outputs = AttemptFile.Outputs(pullRequest: 512, commit: Final.head, verdict: verdict, findings: "RankingUITests が落ちた")
        let review = try await FixMergeFinalPullRequestRunnerTests().reviewed(fixture, "01", outputs: outputs)
        let asking = FixMergeFinalPullRequestRunnerTests().fixJob(fixture, reason: reason, dependsOn: [review.id])
        try await Self.asked(fixture.tasks, job: asking, task: nil, outputs: .init(pullRequest: 512, branch: Final.branches.epic))
        return (fixture, asking)
    }

    func finalResumption(_ fixture: Final, reason: FixTaskInput.Reason, after asking: JobFile) -> JobFile {
        let input = FixTaskInput(pullRequest: 512, head: Final.head, reason: reason, question: "q3")
        return fixture.job(.fixFinalPullRequest, "1F", input: input.jobInput, dependsOn: [asking.id])
    }

    @Test func finalFixQuestionKeepsChangesWithoutPushing() async throws {
        let fixture = try await FixMergeFinalPullRequestRunnerTests().fixture()
        let outputs = AttemptFile.Outputs(pullRequest: 512, commit: Final.head, verdict: .fixCI, findings: "RankingUITests が落ちた")
        let review = try await FixMergeFinalPullRequestRunnerTests().reviewed(fixture, "01", outputs: outputs)
        let runner = FakeTaskRunner([Self.asking()]) { fixture.git.update { $0.dirty = true } }
        let job = FixMergeFinalPullRequestRunnerTests().fixJob(fixture, reason: .ci, dependsOn: [review.id])
        let result = try await FixMergeFinalPullRequestRunnerTests().fixRunner(fixture, runner).execute(job)
        #expect(result.failure == nil)
        #expect(result.outputs?.report?.question != nil)
        #expect(result.outputs?.pullRequest == 512)
        #expect(result.outputs?.branch == Final.branches.epic)
        #expect(result.outputs?.commit == nil)
        #expect(fixture.git.current.dirty)
        #expect(fixture.git.current.commits.isEmpty)
    }

    @Test func finalFixResumesWithMergeInProgressAndChecksConflicts() async throws {
        let (fixture, asking) = try await finalFixture(reason: .conflict, verdict: .fixConflict)
        // 質問したときの作業場所（base の取り込みの途中）が残っている
        fixture.git.update {
            $0.workspaceHead = Final.head
            $0.dirty = true
            $0.conflicted = ["App/RankingView.swift"]
            $0.unresolved = ["App/RankingView.swift"]
        }
        let runner = FakeTaskRunner([FakeTaskRunner.done("名前順を残した。", session: "s-ask"), FakeTaskRunner.done("名前順を残した。", session: "s-ask")])
        let job = finalResumption(fixture, reason: .conflict, after: asking)
        let left = try await FixMergeFinalPullRequestRunnerTests().fixRunner(fixture, runner).execute(job)
        // 取り込み直さず、取り込みの途中でコンフリクトしたままのファイルに印が残っていないかを確かめる
        #expect(left.failure?.failureClass == .conflict)
        #expect(left.failure?.message.contains("App/RankingView.swift") == true)
        #expect(!fixture.git.current.calls.contains { $0.hasPrefix("mergeBase") })
        #expect(fixture.git.current.commits.isEmpty)

        fixture.git.update { $0.unresolved = [] }
        let result = try await FixMergeFinalPullRequestRunnerTests().fixRunner(fixture, runner).execute(job)
        #expect(result.failure == nil)
        #expect(result.outputs?.commit == sha("5"))
        let call = try #require(runner.calls.last)
        #expect(call.kind == .fixFinalPullRequest)
        #expect(call.resume == "s-ask")
        #expect(call.prompt.contains("「名前順」を選んだ"))
        // どのジョブの直しかは、再開したジョブの id で書く
        #expect(fixture.git.current.commits.first?.contains(FixFinalPullRequestRunner.trailer(of: job.id)) == true)
    }

    @Test func finalFixRedoReadsFindingsFromJobBeforeQuestion() async throws {
        let (fixture, asking) = try await finalFixture(reason: .ci, verdict: .fixCI)
        let runner = FakeTaskRunner([FakeTaskRunner.done("落ちたテストを直した。", session: "s-new")]) { fixture.git.update { $0.dirty = true } }
        let job = finalResumption(fixture, reason: .ci, after: asking)
        let result = try await FixMergeFinalPullRequestRunnerTests().fixRunner(fixture, runner).execute(job)

        // 作業場所が無いので取り出し直し、新しい会話で、質問する前の直しが読んだレビューの直すことと、決まったことを渡す
        #expect(result.failure == nil)
        #expect(fixture.git.current.calls.contains("checkOutEpic \(Final.branches.epic)"))
        let call = try #require(runner.calls.first)
        #expect(call.resume == nil)
        #expect(call.prompt.contains("RankingUITests が落ちた"))
        #expect(call.prompt.contains("初めから変更をやり直してください"))
        #expect(call.prompt.contains("補足: 同点は ID 順"))
        #expect(call.failingAtStart == .testFull)
    }
}
