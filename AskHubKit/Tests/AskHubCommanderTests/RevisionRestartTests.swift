@testable import AskHubCommander
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 見直しのまま止まった質問の見直しを、見回りで頼み直す
struct RevisionRestartTests {
    static let repo = ClaudeJobRunnerTests.repo
    static let keep = QuestionJobsTests.result(#"{"decision":"keep","reason":"そのままでよい","rewrite":null}"#)

    let base = ClaudeJobRunnerTests()

    /// q1 に q2・q4 が依存する質問の、q1 を答えて見直しのジョブを作った後
    struct Revising {
        var store: InMemoryStateStore
        var epic: EpicFile
        var revisions: [JobFile]
    }

    func revising() async throws -> Revising {
        let given = try await base.requested()
        let drafts = [
            QuestionJobsTests.draft("q1"),
            QuestionJobsTests.draft("q2", dependsOn: ["q1"]),
            QuestionJobsTests.draft("q4", dependsOn: ["q1"])
        ]
        let answer = base.answer("q1", epic: given.epic, nonce: 1)
        let jobs = try await base.answered([answer], drafts: drafts, in: given.store, epic: given.epic)
        let epic = try #require(try await base.read(EpicFile.self, at: StatePath.epic(Self.repo, given.epic.id), in: given.store))
        return Revising(store: given.store, epic: epic, revisions: jobs.filter { $0.kind == .reviseQuestion })
    }

    func restart(_ given: Revising) async throws -> RevisionRestart.Restarted {
        let jobs = try await base.jobs(given.epic.id, in: given.store)
        return await RevisionRestart(context: base.context(given.store)).restart(epics: [given.epic], jobs: jobs)
    }

    /// ジョブの試行が終わり、見回りで成功にしたとみなす
    func finish(_ job: JobFile, in store: InMemoryStateStore) async throws {
        var done = job
        done.state = .succeeded
        try await base.put(done, at: StatePath.job(Self.repo, epic: job.epic, job: job.id), in: store)
    }

    func state(of question: String, in given: Revising) async throws -> QuestionState? {
        let questions = try await base.read(QuestionsFile.self, at: StatePath.questions(Self.repo, given.epic.id), in: given.store)
        return questions?.questions.first { $0.id == question }?.state
    }

    @Test func restartsRevisionDiscardedAfterAnswerIntentWasReplaced() async throws {
        let given = try await revising()
        #expect(given.revisions.count == 2)
        // 前の司令塔は、同じ回答の 2 回目で回答の意図だけを差し替えた（2026-11-13、askhub-sandbox の epic）
        let path = StatePath.questions(Self.repo, given.epic.id)
        var questions = try #require(try await base.read(QuestionsFile.self, at: path, in: given.store))
        let replaced = base.answer("q1", epic: given.epic, nonce: 2).intent
        questions.questions[0].answer?.intent = replaced
        try await base.put(questions, at: path, in: given.store)
        // 見直しの結果は basis が合わずに捨てられ、ジョブは成功で終わる
        for job in given.revisions {
            guard case .discarded = try await base.runner(given.store, claude: ScriptedRunner([Self.keep])).run(job) else {
                Issue.record("捨てていない")
                return
            }
            try await finish(job, in: given.store)
        }
        #expect(try await state(of: "q2", in: given) == .revising)

        let restarted = try await restart(given)
        #expect(restarted.notes.isEmpty)
        #expect(restarted.created.compactMap { $0.input?["question"]?.stringValue }.sorted() == ["q2", "q4"])
        #expect(restarted.created.allSatisfy { $0.origin == replaced && $0.state == .assigned })
        // 次の周では、頼み直したジョブが待っているので作らない
        #expect(try await restart(given).created.isEmpty)
        // 頼み直したジョブの結果は、今の basis なので書ける
        let job = try #require(restarted.created.first { $0.input?["question"]?.stringValue == "q2" })
        guard case .written = try await base.runner(given.store, claude: ScriptedRunner([Self.keep])).run(job) else {
            Issue.record("書けていない")
            return
        }
        #expect(try await state(of: "q2", in: given) == .open)
    }

    @Test func doesNotRestartWhileRevisionIsPendingOrEpicIsPaused() async throws {
        let given = try await revising()
        #expect(try await restart(given) == RevisionRestart.Restarted())
        // 一時停止した epic は、ジョブが無くても再開するまで頼み直さない
        for job in given.revisions { try await finish(job, in: given.store) }
        var paused = given
        paused.epic.pause = .init(since: given.epic.createdAt, origin: given.revisions[0].origin!)
        try await base.put(paused.epic, at: StatePath.epic(Self.repo, given.epic.id), in: given.store)
        #expect(try await restart(paused).created.isEmpty)
    }

    @Test func restartsOnlyOncePerBasis() async throws {
        let given = try await revising()
        for job in given.revisions { try await finish(job, in: given.store) }
        let restarted = try await restart(given)
        #expect(restarted.created.count == 2)
        // 頼み直したジョブも結果を書かずに終わったら、作り直し続けずに知らせる
        for job in restarted.created { try await finish(job, in: given.store) }
        let again = try await restart(given)
        #expect(again.created.isEmpty)
        #expect(again.notes.count == 2)
        #expect(again.notes.allSatisfy { $0.contains("頼み直した見直し") })
    }
}
