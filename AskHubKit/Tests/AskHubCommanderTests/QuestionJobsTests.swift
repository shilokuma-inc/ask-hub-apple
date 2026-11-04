import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubEpics
import AskHubProtocol
import Foundation
import os
import Testing

/// 決まった結果を順に返し、受け取ったコマンドを記録する
final class ScriptedRunner: CommandRunning {
    private let state: OSAllocatedUnfairLock<(results: [CommandResult], commands: [Command])>

    init(_ results: [CommandResult]) {
        state = OSAllocatedUnfairLock(initialState: (results, []))
    }

    var commands: [Command] { state.withLock { $0.commands } }

    func run(_ command: Command) async throws -> CommandResult {
        state.withLock { state in
            state.commands.append(command)
            guard !state.results.isEmpty else { return CommandResult(status: 1, standardOutput: Data(), standardError: Data()) }
            return state.results.removeFirst()
        }
    }
}

struct QuestionJobsTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let epic = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let key = KeyID(rawValue: String(repeating: "k", count: 43))!
    static let now = Timestamp(rawValue: "2026-11-04T10:00:00Z")!

    static func intent(_ number: Int) -> IntentReference {
        IntentReference(keyId: key, nonce: ULID(rawValue: "01JCN0NCE" + String(format: "%017d", number))!)
    }

    static func draft(_ id: String, options: Int = 2, dependsOn: [String] = []) -> QuestionDraft {
        QuestionDraft(
            id: id,
            title: "\(id) の題",
            why: "画面に関わるため",
            options: (1...options).map { QuestionsFile.Option(label: "案\($0)", effect: "…") },
            recommended: "案1",
            reason: "今の仕組みのままで作れる",
            dependsOn: dependsOn
        )
    }

    static func rewrite(options: Int = 3) -> QuestionRewrite {
        QuestionRewrite(
            title: "書き直した題",
            why: "画面に関わるため",
            options: (1...options).map { QuestionsFile.Option(label: "新\($0)", effect: "…") },
            recommended: "新1",
            reason: "…",
            change: "選択肢を分けた"
        )
    }

    static func answer(_ question: String, mode: AnswerIntent.Mode = .answer, note: String = "", intent: Int) -> AnswerIntent {
        AnswerIntent(
            repo: repo,
            epic: epic,
            question: question,
            questionVersion: 1,
            mode: mode,
            choice: mode == .answer ? "案1" : nil,
            note: note,
            intent: Self.intent(intent)
        )
    }

    static func epicFile() -> EpicFile {
        EpicFile(id: epic, repo: repo, title: "ランキング", stage: .asking, createdAt: now, updatedAt: now)
    }

    // MARK: - 質問づくり

    @Test func makeQuestionsAcceptsValidOutput() {
        let job = MakeQuestionsJob(title: "ランキング", body: "日ごとのランキングを出したい", attachments: ["mock.png"])
        let output = MakeQuestionsJob.Output(summary: "ランキングを作る。", questions: [Self.draft("q1"), Self.draft("q2", dependsOn: ["q1"])])
        #expect(job.problems(in: output).isEmpty)
        #expect(job.problems(in: .init(summary: "何も決めることが無い依頼。", questions: [])).isEmpty)
        #expect(job.prompt.contains("日ごとのランキングを出したい"))
        #expect(job.prompt.contains("mock.png"))
    }

    @Test func makeQuestionsReportsBrokenOutput() {
        let job = MakeQuestionsJob(title: "ランキング", body: "…")
        let drafts = [Self.draft("q1", dependsOn: ["q2"]), Self.draft("q2", dependsOn: ["q1"])]
        let cycle = MakeQuestionsJob.Output(summary: "…", questions: drafts)
        #expect(!job.problems(in: cycle).isEmpty)
        let options = MakeQuestionsJob.Output(summary: "…", questions: [Self.draft("q1", options: 1), Self.draft("q2", options: 5)])
        #expect(job.problems(in: options) == ["q1: 選択肢は 2〜4 個", "q2: 選択肢は 2〜4 個"])
        let tooMany = MakeQuestionsJob.Output(summary: " ", questions: (1...13).map { Self.draft("q\($0)") })
        #expect(job.problems(in: tooMany) == ["summary が空", "質問は 12 個まで"])
    }

    @Test func makeQuestionsIsCorrectedInSameConversation() async throws {
        let broken = #"{"summary":"","questions":[]}"#
        let options = #"[{"label":"日ごと","effect":"…"},{"label":"週ごと","effect":"…"}]"#
        let fields = #""title":"単位","why":"…","recommended":"日ごと","reason":"…","caution":null,"dependsOn":[]"#
        let question = #"{"id":"q1","options":\#(options),\#(fields)}"#
        let fixed = #"{"summary":"ランキングを作る。","questions":[\#(question)]}"#
        let runner = ScriptedRunner([Self.result(broken), Self.result(fixed)])
        let client = ClaudeClient(setup: Self.setup, runner: runner)
        let reply = await MakeQuestionsJob(title: "ランキング", body: "…").ask(
            using: client, repository: Self.repo, facts: "SwiftUI のアプリ", workingDirectory: URL(fileURLWithPath: "/work/repo")
        )
        guard case let .answered(output, session) = reply else { Issue.record("\(reply)"); return }
        #expect(output.questions.map(\.id) == ["q1"])
        #expect(output.questions.first?.caution == nil)
        #expect(session.calls == 2)
        let first = runner.commands[0].arguments
        #expect(first.firstIndex(of: "--model").map { first[$0 + 1] } == "claude-opus-5-5")
        #expect(first.firstIndex(of: "--append-system-prompt").map { first[$0 + 1].contains("SwiftUI のアプリ") } == true)
        #expect(runner.commands[1].arguments[1].contains("summary が空"))
        #expect(runner.commands[0].timeout == .seconds(15 * 60))
    }

    // MARK: - 説明

    private func clarifying() throws -> QuestionsFile {
        let file = try QuestionFlow.start([Self.draft("q1")]).questions
        let answer = Self.answer("q1", mode: .clarify, note: "保存とは？", intent: 1)
        let change = try QuestionFlow.accept(answer, epic: Self.epicFile(), questions: file, at: Self.now)
        return change.questions
    }

    @Test func explainChecksTextAndRewrite() throws {
        let job = ExplainJob(questions: try clarifying(), question: "q1", asked: Self.intent(1))
        #expect(job.prompt.contains("保存とは？"))
        #expect(job.problems(in: .init(text: "保存は…")).isEmpty)
        #expect(job.problems(in: .init(text: "保存は…", rewrite: Self.rewrite())).isEmpty)
        #expect(job.problems(in: .init(text: "")) == ["説明が空"])
        #expect(job.problems(in: .init(text: "…", rewrite: Self.rewrite(options: 5))) == ["q1: 選択肢は 2〜4 個"])
        // 頼んだ後に状態が変わっていても、Claude には直させない（書くときに捨てる）
        let stale = ExplainJob(questions: try clarifying(), question: "q1", asked: Self.intent(9))
        #expect(stale.problems(in: .init(text: "…")).isEmpty)
    }

    // MARK: - 見直し

    private func revising() throws -> (QuestionsFile, RevisionBasis) {
        let file = try QuestionFlow.start([Self.draft("q1"), Self.draft("q2", dependsOn: ["q1"])]).questions
        let answer = Self.answer("q1", note: "夜間は長め", intent: 1)
        let change = try QuestionFlow.accept(answer, epic: Self.epicFile(), questions: file, at: Self.now)
        guard case let .revise(_, basis)? = change.effects.first else { throw CancellationError() }
        return (change.questions, basis)
    }

    @Test func reviseChecksDecision() throws {
        let (file, basis) = try revising()
        let job = ReviseQuestionJob(questions: file, question: "q2", basis: basis)
        #expect(job.prompt.contains("回答: 案1"))
        #expect(job.prompt.contains("補足: 夜間は長め"))
        #expect(job.problems(in: .init(decision: .keep, reason: "そのままでよい")).isEmpty)
        #expect(job.problems(in: .init(decision: .drop, reason: "要らなくなった")).isEmpty)
        #expect(job.outcome(of: .init(decision: .drop, reason: "要らなくなった")) == .drop(reason: "要らなくなった"))
        #expect(job.problems(in: .init(decision: .rewrite, reason: "…", rewrite: Self.rewrite())).isEmpty)
        #expect(job.problems(in: .init(decision: .rewrite, reason: "…")) == ["decision が rewrite なのに、rewrite が無い"])
        #expect(job.problems(in: .init(decision: .keep, reason: "")) == ["reason が空"])
    }

    @Test func schemasAreStable() {
        // 結果の形を変えたら、依頼の文とテストも合わせて見直す
        let schemas = [MakeQuestionsJob.outputSchema, ExplainJob.outputSchema, ReviseQuestionJob.outputSchema]
        for schema in schemas {
            #expect(schema["type"] == .string("object"))
            #expect(schema["additionalProperties"] == .bool(false))
        }
        #expect(ExplainJob.outputSchema["required"] == .array([.string("text")]))
    }

    // MARK: - 下ごしらえ

    static let setup = ClaudeSetup(
        executable: URL(fileURLWithPath: "/opt/claude/claude"),
        configDirectory: URL(fileURLWithPath: "/tmp/askhub/claude"),
        homeDirectory: URL(fileURLWithPath: "/tmp/askhub"),
        temporaryDirectory: URL(fileURLWithPath: "/tmp/askhub/tmp"),
        oauthToken: "sk-ant-oat01-" + String(repeating: "x", count: 40)
    )

    static func result(_ structuredOutput: String) -> CommandResult {
        let object: [String: Any] = [
            "type": "result", "subtype": "success", "is_error": false, "result": structuredOutput,
            "session_id": "s-1", "total_cost_usd": 0.1, "modelUsage": ["claude-opus-5-5": [:]],
            "structured_output": (try? JSONSerialization.jsonObject(with: Data(structuredOutput.utf8))) ?? NSNull()
        ]
        let line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return CommandResult(status: 0, standardOutput: line, standardError: Data())
    }
}
