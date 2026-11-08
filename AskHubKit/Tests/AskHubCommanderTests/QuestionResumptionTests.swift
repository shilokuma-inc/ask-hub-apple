import AskHubClaude
@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

/// 答えで再開するとき、Claude の CLI が会話を再開できなかった（`--resume` の失敗）結果から、新しい会話に切り替えるまで
/// （`ClaudeClient` の失敗の分け方と `TaskRunner` を通して確かめる）
struct QuestionResumptionTests {
    static func resumption() throws -> QuestionResumption {
        let question = QuestionsFile.Question(
            id: "q3",
            title: "同点の並び",
            why: "同点のときの並びが決まっていない",
            options: TaskJobsTests.question.options,
            recommended: "名前順",
            reason: "探しやすい",
            round: 2,
            state: .answered,
            answer: TaskQuestionRunnerTests.answer,
            job: ULID(rawValue: "01JCJ0B0000000000000000002")!,
            task: "t2"
        )
        let answered = try #require(AnsweredQuestion(question))
        return QuestionResumption(answered: answered, answers: [answered], mac: TaskJobFixture.mac, session: "s-ask")
    }

    /// CLI の失敗（終了コード 1、標準エラーに理由）
    static func failed(_ message: String) -> CommandResult {
        CommandResult(status: 1, standardOutput: Data(), standardError: Data(message.utf8))
    }

    func answer(_ claude: ScriptedRunner) async throws -> TaskReply {
        let runner = TaskRunnerTests.runner(claude, builds: FakeBuilds([]))
        let job = ImplementTaskJob(goal: TaskJobsTests.goal(), task: TaskJobsTests.goal().tasks[1])
        let resumption = try Self.resumption()
        return await resumption.answer(job, kept: true) { await runner.run($0, in: TaskRunnerTests.workspace) }
    }

    @Test func switchesToNewConversationWhenConversationIsNotFound() async throws {
        let claude = ScriptedRunner([
            Self.failed("No conversation found with session ID: s-ask"),
            TaskRunnerTests.result("done", summary: "並びを名前順にした。", session: "s-new")
        ])
        let reply = try await answer(claude)
        guard case let .reported(report, run) = reply else { Issue.record("\(reply)"); return }
        #expect(report.summary == "並びを名前順にした。")
        #expect(run.session?.id == "s-new")
        // 1 回目は質問した会話を再開し、再開できなかったので、2 回目は新しい会話で途中の変更から続けさせる
        #expect(claude.commands.count == 2)
        #expect(TaskRunnerTests.value("--resume", in: claude.commands[0]) == "s-ask")
        #expect(!claude.commands[1].arguments.contains("--resume"))
        #expect(TaskRunnerTests.value("-p", in: claude.commands[1])?.contains("途中の変更から続けてください") == true)
    }

    @Test func keepsFailureThatIsNotAboutConversation() async throws {
        // 利用上限は、会話を再開できないのではない（新しい会話に切り替えずに、試行の失敗にする）
        let claude = ScriptedRunner([Self.failed("Claude AI usage limit reached")])
        let reply = try await answer(claude)
        guard case let .failed(failure, _) = reply else { Issue.record("\(reply)"); return }
        #expect(failure.failureClass == .usageLimit)
        #expect(!reply.couldNotResume)
        #expect(claude.commands.count == 1)
    }
}
