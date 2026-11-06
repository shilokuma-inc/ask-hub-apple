import AskHubClaude
@testable import AskHubCommander
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// Claude の結果を書く前の確かめ（読み直し・取り消し・添付・質問の一覧）
extension ClaudeJobRunnerTests {
    @Test func discardsCheckWhenAnswersChangedMeanwhile() async throws {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        // 頼んでいる間に、人が答え直して、また着手前の確認に戻った（段階は checking のまま、質問の一覧だけが変わる）
        let draft = try Self.decodeDraft(Self.question("q1"))
        let changed = try QuestionFlow.append([draft], round: 2, to: QuestionsFile(questions: [])).questions
        let path = StatePath.questions(Self.repo, epic.id)
        let data = try StateFileCoder.encode(changed)
        let ready = Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))
        let claude = InterruptingRunner(interrupt: { await store.put(path, data: data) }, result: ready)
        guard case .discarded = try await runner(store, claude: claude).run(job) else { Issue.record("捨てていない"); return }
        #expect(try await read(GoalFile.self, at: StatePath.goal(Self.repo, epic.id), in: store) == nil)
        #expect(try await read(ReadinessFile.self, at: StatePath.readiness(Self.repo, epic.id), in: store) == nil)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .checking)
    }

    @Test func discardsResultOfCanceledJob() async throws {
        let given = try await checking()
        let (store, epic, job) = (given.store, given.epic, given.job)
        var canceled = job
        canceled.state = .canceled
        let path = StatePath.job(Self.repo, epic: epic.id, job: job.id)
        let data = try StateFileCoder.encode(canceled)
        let ready = Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))
        let claude = InterruptingRunner(interrupt: { await store.put(path, data: data) }, result: ready)
        guard case .discarded = try await runner(store, claude: claude).run(job) else { Issue.record("捨てていない"); return }
        #expect(try await read(GoalFile.self, at: StatePath.goal(Self.repo, epic.id), in: store) == nil)
    }

    @Test func checkFailsWithoutQuestionList() async throws {
        let given = try await requested()
        var epic = given.epic
        epic.stage = .checking
        try await put(epic, at: StatePath.epic(Self.repo, epic.id), in: given.store)
        let origin = try #require(epic.origin)
        let job = context(given.store).claudeJob(.checkReadiness, for: epic, origin: origin, seed: "", input: [:])
        let claude = ScriptedRunner([])
        let outcome = try await runner(given.store, claude: claude).run(job)
        guard case let .failed(failure, nil) = outcome else { Issue.record("止めていない"); return }
        #expect(failure.failureClass == .unexpected)
        #expect(claude.commands.isEmpty)
    }

    @Test func checkReadsRequestAttachments() async throws {
        let given = try await requested(attachments: [("mock.png", Data("png".utf8))])
        let made = ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)])
        _ = try await runner(given.store, claude: made).run(given.job)
        let job = try #require(try await jobs(given.epic.id, in: given.store).first { $0.kind == .checkReadiness })
        let claude = ScriptedRunner([Self.output(CheckReadinessJob.Output(verdict: .ready, reason: "そろった", goal: Self.goal()))])
        guard case .written = try await runner(given.store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let arguments = try #require(claude.commands.first).arguments
        let attachments = directory.appendingPathComponent("attachments/\(job.id)")
        #expect(arguments.firstIndex(of: "--add-dir").map { arguments[$0 + 1] } == attachments.path)
        #expect(arguments[1].contains(attachments.appendingPathComponent("1/mock.png").path))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func refusesAttachmentReplacedAfterRequest() async throws {
        let given = try await requested(attachments: [("mock.png", Data("png".utf8))])
        let nonce = try #require(given.epic.origin?.nonce)
        await given.store.put(StatePath.attachment(device: keyID, nonce: nonce, number: 1), data: Data("gif".utf8))
        let claude = ScriptedRunner([])
        let outcome = try await runner(given.store, claude: claude).run(given.job)
        guard case let .failed(failure, nil) = outcome else { Issue.record("止めていない"); return }
        #expect(failure.message.contains("ハッシュ"))
        #expect(claude.commands.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// 呼ばれた順を記録する
actor EventLog {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

struct CommanderLockTests {
    @Test func runsOneAtATime() async throws {
        let lock = CommanderLock()
        let log = EventLog()
        let (release, releaser) = AsyncStream<Void>.makeStream()
        let first = Task {
            try await lock.withLock { () throws(CommanderError) in
                await log.append("first-start")
                for await _ in release { break }
                await log.append("first-end")
            }
        }
        while await log.events.isEmpty { await Task.yield() }
        let second = Task {
            try await lock.withLock { () throws(CommanderError) in await log.append("second") }
        }
        // 2 つ目が待ちに入ったのを確かめてから比べる（入らなければ、先の処理を放して失敗にする）
        var waited = 0
        while await lock.waitingCount == 0, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(await lock.waitingCount == 1)
        // 先に入った処理が終わるまで、次は入らない
        #expect(await log.events == ["first-start"])
        releaser.yield(())
        try await first.value
        try await second.value
        #expect(await log.events == ["first-start", "first-end", "second"])
    }
}
