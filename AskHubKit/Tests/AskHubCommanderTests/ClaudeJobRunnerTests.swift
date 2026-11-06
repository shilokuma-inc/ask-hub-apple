import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 決まったフォルダを返す作業場所
struct FixedWorkspace: RepositoryWorkspace {
    var directory: URL
    var failure: WorkspaceError?

    func prepare(_ repo: RepositoryFullName, for job: ULID) async throws(WorkspaceError) -> PreparedWorkspace {
        if let failure { throw failure }
        return PreparedWorkspace(directory: directory.appendingPathComponent("repo"), facts: "SwiftUI のアプリ")
    }

    func attachmentsDirectory(for job: ULID) async throws(WorkspaceError) -> URL {
        let url = directory.appendingPathComponent("attachments/\(job)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .failed(error.localizedDescription)
        }
        return url
    }

    func release(_ job: ULID) async {}
}

/// Claude を呼ぶジョブを実行し、結果を状態リポジトリに書く
struct ClaudeJobRunnerTests {
    static let repo = EpicHandlersTests.repo
    static let commander = EpicHandlersTests.commander
    static let now = EpicHandlersTests.now

    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeJobRunnerTests-\(UUID().uuidString)")

    func context(_ store: InMemoryStateStore) -> CommanderContext {
        CommanderContext(store: store, mac: Self.commander) { Self.now }
    }

    func runner(_ store: InMemoryStateStore, claude: any CommandRunning, workspace failure: WorkspaceError? = nil) -> ClaudeJobRunner {
        ClaudeJobRunner(
            context: context(store),
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: claude),
            workspace: FixedWorkspace(directory: directory, failure: failure),
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation])
        )
    }

    /// 依頼を受け付けた後の状態
    struct Requested {
        var store: InMemoryStateStore
        var epic: EpicFile
        var job: JobFile
    }

    /// 署名した依頼を置き、受け付けて、epic と質問づくりのジョブを作る
    func requested(attachments: [(name: String, data: Data)] = []) async throws -> Requested {
        let store = InMemoryStateStore()
        let file = RepositoryFile(repo: Self.repo, platform: .apple, maxConcurrentEpics: 1, addedAt: Timestamp(Self.now))
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        let nonce = ULID.generate(at: Self.now)
        var items: [JSONValue] = []
        for (index, attachment) in attachments.enumerated() {
            let digest = SHA256.hash(data: attachment.data).map { String(format: "%02x", $0) }.joined()
            items.append(.object([
                "n": .integer(Int64(index + 1)), "name": .string(attachment.name),
                "size": .integer(Int64(attachment.data.count)), "sha256": .string(digest)
            ]))
            await store.put(StatePath.attachment(device: keyID, nonce: nonce, number: index + 1), data: attachment.data)
        }
        var payload: [String: JSONValue] = ["title": .string("ランキング"), "body": .string("日ごとに入れ替えたい")]
        if !items.isEmpty { payload["attachments"] = .array(items) }
        let envelope = IntentEnvelope(
            kind: "request", repo: Self.repo, payload: payload, issuedAt: Timestamp(Self.now), nonce: nonce, keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        let intake = IntentIntake(
            context: context(store),
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["request": RequestHandler()]
        )
        #expect(try await intake.processPending() == [.accepted(kind: "request")])
        let epicID = RequestHandler.epicID(for: IntentReference(keyId: keyID, nonce: nonce))
        let epic = try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epicID), in: store))
        let job = try #require(try await jobs(epicID, in: store).first)
        return Requested(store: store, epic: epic, job: job)
    }

    func read<File: StateFile>(_ type: File.Type, at path: String, in store: InMemoryStateStore) async throws -> File? {
        try await store.data(at: path).map { try StateFileCoder.decode(File.self, from: $0) }
    }

    func put<File: StateFile>(_ file: File, at path: String, in store: InMemoryStateStore) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    func jobs(_ epic: ULID, in store: InMemoryStateStore) async throws -> [JobFile] {
        var jobs: [JobFile] = []
        for entry in try await store.list(StatePath.jobs(Self.repo, epic: epic)) ?? [] {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }

    static let options = #"[{"label":"案1","effect":"…"},{"label":"案2","effect":"…"}]"#

    static func question(_ id: String, dependsOn: [String] = []) -> String {
        let depends = dependsOn.map { "\"\($0)\"" }.joined(separator: ",")
        let fields = #""title":"\#(id) の題","why":"…","recommended":"案1","reason":"…","caution":null"#
        return #"{"id":"\#(id)","options":\#(options),\#(fields),"dependsOn":[\#(depends)]}"#
    }

    // MARK: - 質問づくり

    @Test func makeQuestionsWritesQuestionsAndWaitsForAnswers() async throws {
        let given = try await requested(attachments: [("mock.png", Data("png".utf8)), ("mock.png", Data("jpg".utf8))])
        let (store, epic, job) = (given.store, given.epic, given.job)
        let output = #"{"summary":"日ごとのランキングを作る。","questions":[\#(Self.question("q1")),\#(Self.question("q2", dependsOn: ["q1"]))]}"#
        let claude = ScriptedRunner([QuestionJobsTests.result(output)])
        guard case let .written(session) = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        #expect(session.model == "claude-opus-5-5")

        let questions = try #require(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store))
        #expect(questions.questions.map(\.state) == [.open, .locked])
        let written = try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store))
        #expect(written.stage == .asking)
        #expect(written.summary == "日ごとのランキングを作る。")
        #expect(try await jobs(epic.id, in: store).map(\.kind) == [.makeQuestions])

        // 添付は、名前が重なっても番号ごとのフォルダに置き、Claude が読んでよい場所として渡す
        let arguments = try #require(claude.commands.first).arguments
        let attachments = directory.appendingPathComponent("attachments/\(job.id)")
        #expect(arguments.firstIndex(of: "--add-dir").map { arguments[$0 + 1] } == attachments.path)
        #expect(try Data(contentsOf: attachments.appendingPathComponent("1/mock.png")) == Data("png".utf8))
        #expect(try Data(contentsOf: attachments.appendingPathComponent("2/mock.png")) == Data("jpg".utf8))
        #expect(arguments[1].contains(attachments.appendingPathComponent("2/mock.png").path))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func makeQuestionsWithoutQuestionsChecksReadiness() async throws {
        let given = try await requested()
        let (store, epic, job) = (given.store, given.epic, given.job)
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let written = try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store))
        #expect(written.stage == .checking)
        let check = try #require(try await jobs(epic.id, in: store).first { $0.kind == .checkReadiness })
        // 質問づくりのジョブが成功してから動く
        #expect(check.dependsOn == [job.id])
        // 結果を書いた後は段階が進んでいるので、やり直しても Claude を呼ばずに捨てる
        guard case .discarded = try await runner(store, claude: claude).run(job) else { Issue.record("捨てていない"); return }
        #expect(claude.commands.count == 1)
    }

    @Test func makeQuestionsKeepsQuestionsWrittenInEarlierRound() async throws {
        let given = try await requested()
        let (store, epic, job) = (given.store, given.epic, given.job)
        // 前の周で質問の一覧まで書き、epic を変える前に止まった
        let earlier = try QuestionFlow.start(try [Self.decodeDraft(Self.question("q1"))]).questions
        try await put(earlier, at: StatePath.questions(Self.repo, epic.id), in: store)
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"summary":"文言を直す。","questions":[]}"#)])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        #expect(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store) == earlier)
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .asking)
        #expect(try await jobs(epic.id, in: store).map(\.kind) == [.makeQuestions])
    }

    @Test func workspaceFailureIsReportedWithoutCallingClaude() async throws {
        let given = try await requested()
        let (store, job) = (given.store, given.job)
        let claude = ScriptedRunner([])
        let outcome = try await runner(store, claude: claude, workspace: .unavailable("502")).run(job)
        guard case let .failed(failure, nil) = outcome else { Issue.record("\(outcome)"); return }
        #expect(failure.failureClass == .githubOutage)
        #expect(claude.commands.isEmpty)
    }

    @Test func discardsJobsOfStartedOrAbandonedEpic() async throws {
        let given = try await requested()
        let (store, epic, job) = (given.store, given.epic, given.job)
        for stage in [EpicStage.running, .abandoned] {
            var changed = epic
            changed.stage = stage
            try await put(changed, at: StatePath.epic(Self.repo, epic.id), in: store)
            let claude = ScriptedRunner([])
            guard case .discarded = try await runner(store, claude: claude).run(job) else { Issue.record("\(stage) で捨てていない"); return }
            #expect(claude.commands.isEmpty)
        }
    }

    @Test func refusesRequestWithUnknownSignature() async throws {
        let given = try await requested()
        let (store, job) = (given.store, given.job)
        let other = P256.Signing.PrivateKey()
        let runner = ClaudeJobRunner(
            context: context(store),
            client: ClaudeClient(setup: QuestionJobsTests.setup, runner: ScriptedRunner([])),
            workspace: FixedWorkspace(directory: directory),
            verifier: IntentVerifier(publicKeys: [keyID: other.publicKey.derRepresentation])
        )
        guard case let .failed(failure, nil) = try await runner.run(job) else { Issue.record("断っていない"); return }
        #expect(failure.failureClass == .unexpected)
    }

    @Test func stageIsNotChangedAfterStartOrAbandon() async throws {
        let given = try await requested()
        for stage in [EpicStage.running, .abandoned] {
            var epic = given.epic
            epic.stage = stage
            try await put(epic, at: StatePath.epic(Self.repo, epic.id), in: given.store)
            try await context(given.store).setStage(.asking, of: epic)
            #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: given.store)?.stage == stage)
        }
    }

    // MARK: - 説明・見直し

    /// 質問の一覧と epic を置き、回答を受け付けた後のジョブを作る
    func answered(
        _ answers: [AnswerIntent],
        drafts: [QuestionDraft],
        in store: InMemoryStateStore,
        epic: EpicFile
    ) async throws -> [JobFile] {
        var questions = try QuestionFlow.start(drafts).questions
        var epic = epic
        epic.stage = .asking
        try await put(epic, at: StatePath.epic(Self.repo, epic.id), in: store)
        for answer in answers {
            let change = try QuestionFlow.accept(answer, epic: epic, questions: questions, at: Timestamp(Self.now))
            try await context(store).perform(change.effects, for: epic, origin: answer.intent)
            questions = change.questions
        }
        try await put(questions, at: StatePath.questions(Self.repo, epic.id), in: store)
        return try await jobs(epic.id, in: store).filter { $0.kind != .makeQuestions }
    }

    func answer(
        _ question: String,
        mode: AnswerIntent.Mode = .answer,
        note: String = "",
        epic: EpicFile,
        nonce: Int
    ) -> AnswerIntent {
        AnswerIntent(
            repo: Self.repo,
            epic: epic.id,
            question: question,
            questionVersion: 1,
            mode: mode,
            choice: mode == .answer ? "案1" : nil,
            note: note,
            intent: IntentReference(keyId: keyID, nonce: ULID(rawValue: "01JCN0NCE" + String(format: "%017d", nonce))!)
        )
    }

    @Test func explainWritesExplanation() async throws {
        let given = try await requested()
        let (store, epic) = (given.store, given.epic)
        let clarify = answer("q1", mode: .clarify, note: "保存とは？", epic: epic, nonce: 1)
        let jobs = try await answered([clarify], drafts: [QuestionJobsTests.draft("q1")], in: store, epic: epic)
        let job = try #require(jobs.first { $0.kind == .explain })
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"text":"端末に残すことです。","rewrite":null}"#)])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let written = try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store)
        let question = try #require(written?.questions.first)
        #expect(question.state == .open)
        #expect(question.explanations.map(\.text) == ["端末に残すことです。"])
        // 書いた後に同じジョブをやり直しても、説明を待っていないので捨てる
        let again = ScriptedRunner([QuestionJobsTests.result(#"{"text":"別の説明。","rewrite":null}"#)])
        guard case .discarded = try await runner(store, claude: again).run(job) else { Issue.record("捨てていない"); return }
    }

    @Test func reviseQuestionDropsQuestionAndChecksReadiness() async throws {
        let given = try await requested()
        let (store, epic) = (given.store, given.epic)
        let drafts = [QuestionJobsTests.draft("q1"), QuestionJobsTests.draft("q2", dependsOn: ["q1"])]
        let jobs = try await answered([answer("q1", epic: epic, nonce: 1)], drafts: drafts, in: store, epic: epic)
        let job = try #require(jobs.first { $0.kind == .reviseQuestion })
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"decision":"drop","reason":"日ごとに決まったので要らない","rewrite":null}"#)])
        guard case .written = try await runner(store, claude: claude).run(job) else { Issue.record("書けていない"); return }
        let questions = try #require(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store))
        #expect(questions.questions.map(\.state) == [.answered, .dropped])
        #expect(try await read(EpicFile.self, at: StatePath.epic(Self.repo, epic.id), in: store)?.stage == .checking)
        let check = try #require(try await self.jobs(epic.id, in: store).first { $0.kind == .checkReadiness })
        #expect(check.dependsOn == [job.id])
    }

    @Test func reviseQuestionIsDiscardedWhenAnswerChanged() async throws {
        let given = try await requested()
        let (store, epic) = (given.store, given.epic)
        let drafts = [QuestionJobsTests.draft("q1"), QuestionJobsTests.draft("q2", dependsOn: ["q1"])]
        let first = try await answered([answer("q1", epic: epic, nonce: 1)], drafts: drafts, in: store, epic: epic)
        let job = try #require(first.first { $0.kind == .reviseQuestion })
        // 見直しを頼んだ後に、人が前提の質問を別の答えで答え直した
        var changed = answer("q1", epic: epic, nonce: 2)
        changed.choice = "案2"
        _ = try await answered([answer("q1", epic: epic, nonce: 1), changed], drafts: drafts, in: store, epic: epic)
        let before = try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store)
        let claude = ScriptedRunner([QuestionJobsTests.result(#"{"decision":"keep","reason":"そのままでよい","rewrite":null}"#)])
        guard case .discarded = try await runner(store, claude: claude).run(job) else { Issue.record("捨てていない"); return }
        #expect(try await read(QuestionsFile.self, at: StatePath.questions(Self.repo, epic.id), in: store) == before)
    }

    @Test func malformedInputIsReported() async throws {
        let given = try await requested()
        let (store, epic) = (given.store, given.epic)
        let origin = IntentReference(keyId: keyID, nonce: ULID.generate(at: Self.now))
        let job = context(store).claudeJob(.explain, for: epic, origin: origin, seed: "q1", input: ["question": .integer(1)])
        let claude = ScriptedRunner([])
        guard case let .failed(failure, nil) = try await runner(store, claude: claude).run(job) else { Issue.record("断っていない"); return }
        #expect(failure.failureClass == .unexpected)
        #expect(claude.commands.isEmpty)
    }

    static func decodeDraft(_ json: String) throws -> QuestionDraft {
        try JSONDecoder().decode(QuestionDraft.self, from: Data(json.utf8))
    }
}
