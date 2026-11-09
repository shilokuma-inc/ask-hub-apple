@testable import AskHubClaude
import AskHubCommands
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

struct ClaudeClientTests {
    struct Answer: Codable, Equatable, Sendable {
        var answer: String
    }

    static let token = "sk-ant-oat01-" + String(repeating: "x", count: 40)
    static let setup = ClaudeSetup(
        executable: URL(fileURLWithPath: "/opt/claude/2.1.317/claude"),
        configDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/AskHub/claude"),
        homeDirectory: URL(fileURLWithPath: "/Users/me"),
        temporaryDirectory: URL(fileURLWithPath: "/tmp/askhub"),
        oauthToken: token
    )
    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object(["answer": .object(["type": .string("string")])]),
        "required": .array([.string("answer")])
    ])

    private func request(prompt: String = "答えてください") -> ClaudeRequest {
        ClaudeRequest(
            prompt: prompt,
            systemPrompt: "読むだけにしてください",
            model: "claude-opus-5-5",
            outputSchema: Self.schema,
            workingDirectory: URL(fileURLWithPath: "/work/repo"),
            timeout: .seconds(600)
        )
    }

    /// `claude -p --output-format json` の結果の 1 行（手元で実際に呼んで確かめた形を短くしたもの）
    static func result(
        output: String? = #"{"answer":"ok"}"#,
        subtype: String = "success",
        isError: Bool = false,
        text: String = #"{"answer":"ok"}"#,
        models: [String] = ["claude-opus-5-5"],
        apiErrorStatus: Int? = nil,
        session: String = "85646622-763a-4b15-a8d8-78a5839c0bb6",
        cost: Double = 0.0154
    ) -> CommandResult {
        var object: [String: Any] = [
            "type": "result", "subtype": subtype, "is_error": isError, "result": text, "session_id": session,
            "total_cost_usd": cost, "num_turns": 2, "terminal_reason": "completed",
            "modelUsage": Dictionary(uniqueKeysWithValues: models.map { ($0, ["inputTokens": 2, "outputTokens": 56]) }),
            "api_error_status": apiErrorStatus.map { $0 as Any } ?? NSNull()
        ]
        if let output { object["structured_output"] = try? JSONSerialization.jsonObject(with: Data(output.utf8)) }
        let line = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return CommandResult(status: isError ? 1 : 0, standardOutput: line + Data("\n".utf8), standardError: Data())
    }

    private func ask(
        _ results: [CommandResult],
        check: @escaping @Sendable (Answer) -> [String] = { _ in [] }
    ) async -> (ClaudeReply<Answer>, ScriptedRunner) {
        let runner = ScriptedRunner(results)
        let client = ClaudeClient(setup: Self.setup, runner: runner, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let now = Date(timeIntervalSince1970: 1_793_757_600) // 2026-11-04T02:00:00Z（東京は 11:00）
        return (await client.ask(request(), as: Answer.self, now: { now }, check: check), runner)
    }

    // MARK: - 組み立て

    @Test func buildsRestrictedReadOnlyCommand() throws {
        let command = try ClaudeCommandLine.command(for: request(), setup: Self.setup)
        #expect(command.executable.path == "/opt/claude/2.1.317/claude")
        #expect(command.workingDirectory.path == "/work/repo")
        #expect(Array(command.arguments.prefix(2)) == ["-p", "答えてください"])
        for flag in ["--restricted", "--strict-mcp-config"] {
            #expect(command.arguments.contains(flag))
        }
        func value(_ flag: String) -> String? {
            command.arguments.firstIndex(of: flag).map { command.arguments[$0 + 1] }
        }
        #expect(value("--output-format") == "json")
        #expect(value("--model") == "claude-opus-5-5")
        #expect(value("--permission-mode") == "dontAsk")
        #expect(value("--tools") == "Read,Grep,Glob")
        #expect(value("--settings") == #"{"permissions":{"allow":["Read","Grep","Glob"]}}"#)
        #expect(value("--json-schema") == CanonicalJSON.string(for: Self.schema))
        #expect(value("--append-system-prompt") == "読むだけにしてください")
        #expect(!command.arguments.contains("--resume"))
        #expect(!command.arguments.contains("bypassPermissions"))
    }

    @Test func enablesSandboxOnlyWhenAsked() throws {
        var editing = request()
        editing.tools = ["Read", "Edit"]
        editing.sandboxed = true
        let arguments = try ClaudeCommandLine.command(for: editing, setup: Self.setup).arguments
        #expect(arguments.firstIndex(of: "--settings").map { arguments[$0 + 1] }
            == #"{"permissions":{"allow":["Read","Edit"]},"sandbox":{"allowUnsandboxedCommands":false,"enabled":true}}"#)
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "Read,Edit")
    }

    @Test func passesOnlyClaudeAuthenticationInEnvironment() throws {
        let environment = try ClaudeCommandLine.command(for: request(), setup: Self.setup).environment
        let expected: Set = ["HOME", "PATH", "TMPDIR", "LANG", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "DISABLE_AUTOUPDATER"]
        #expect(Set(environment.keys) == expected)
        #expect(environment["CLAUDE_CODE_OAUTH_TOKEN"] == Self.token)
        #expect(environment["CLAUDE_CONFIG_DIR"] == "/Users/me/Library/Application Support/AskHub/claude")
        #expect(!"\(Self.setup)".contains(Self.token))
    }

    @Test func refusesPromptsThatCannotBePassedSafely() {
        #expect(throws: ClaudeCommandLine.Problem.promptLooksLikeOption) {
            try ClaudeCommandLine.command(for: request(prompt: "--dangerously-skip-permissions"), setup: Self.setup)
        }
        // 依頼のほか、決まりの文・結果の形などの引数の全体で数える
        do throws(ClaudeCommandLine.Problem) {
            _ = try ClaudeCommandLine.command(for: request(prompt: String(repeating: "a", count: 256_000)), setup: Self.setup)
            Issue.record("大きすぎる依頼を断らなかった")
        } catch let .argumentsTooLarge(bytes) {
            #expect(bytes > 256_000)
        } catch {
            Issue.record("\(error)")
        }
    }

    // MARK: - 結果

    @Test func returnsStructuredOutputWithSession() async throws {
        let (reply, runner) = await ask([Self.result()])
        guard case let .answered(answer, session) = reply else { Issue.record("\(reply)"); return }
        #expect(answer == Answer(answer: "ok"))
        #expect(session.id == "85646622-763a-4b15-a8d8-78a5839c0bb6")
        #expect(session.attemptRecord == AttemptFile.Claude(model: "claude-opus-5-5", session: session.id, estimatedCostUsd: 0.0154))
        #expect(runner.commands.count == 1)
    }

    @Test func resumesConversationToCorrectInvalidOutput() async throws {
        let (reply, runner) = await ask(
            // 再開した結果の費用は、会話全体の累計
            [Self.result(output: #"{"answer":""}"#), Self.result(output: #"{"answer":"ok"}"#, cost: 0.0254)],
            check: { $0.answer.isEmpty ? ["answer が空"] : [] }
        )
        guard case let .answered(answer, session) = reply else { Issue.record("\(reply)"); return }
        #expect(answer.answer == "ok")
        #expect(session.calls == 2)
        #expect(abs((session.estimatedCostUsd ?? 0) - 0.0254) < 0.000_001)
        let second = runner.commands[1].arguments
        #expect(second[1].contains("- answer が空"))
        #expect(second.firstIndex(of: "--resume").map { second[$0 + 1] } == "85646622-763a-4b15-a8d8-78a5839c0bb6")
    }

    @Test func givesUpAfterCorrectionsRunOut() async throws {
        let (reply, runner) = await ask(Array(repeating: Self.result(output: #"{"other":1}"#), count: 5))
        guard case let .failed(failure, session) = reply else { Issue.record("\(reply)"); return }
        #expect(failure.failureClass == .unexpected)
        #expect(runner.commands.count == 3)
        #expect(session?.calls == 3)
    }

    @Test func stopsCorrectionsAtDeadline() async throws {
        let start = Date(timeIntervalSince1970: 1_793_757_600)
        // 呼ぶたびに 60 秒進む時計。期限は始めてから 100 秒後
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        let now: @Sendable () -> Date = { ticks.withLock { $0 += 1; return start.addingTimeInterval(Double($0) * 60) } }
        let runner = ScriptedRunner(Array(repeating: Self.result(output: #"{"answer":""}"#), count: 3))
        let client = ClaudeClient(setup: Self.setup, runner: runner)
        let reply = await client.ask(request(), as: Answer.self, now: now, deadline: start.addingTimeInterval(100)) { answer in
            answer.answer.isEmpty ? ["answer が空"] : []
        }
        guard case let .failed(failure, session) = reply else { Issue.record("\(reply)"); return }
        #expect(failure.failureClass == .timeout)
        #expect(session?.calls == 1)
        // 1 回目は残りの 40 秒で打ち切り、期限を過ぎた後の直しは呼ばない
        #expect(runner.commands.map(\.timeout) == [.seconds(40)])

        let late = await client.ask(request(), as: Answer.self, deadline: Date(timeIntervalSince1970: 0))
        guard case .failed(let failure, nil) = late else { Issue.record("\(late)"); return }
        #expect(failure.failureClass == .timeout)
        #expect(runner.commands.count == 1)
    }

    @Test func stopsWhenAnotherModelAnswered() async throws {
        let (reply, _) = await ask([Self.result(models: ["claude-sonnet-5-5"])])
        guard case let .failed(failure, _) = reply else { Issue.record("\(reply)"); return }
        #expect(failure.failureClass == .unexpected)
        #expect(failure.message.contains("claude-sonnet-5-5"))
    }

    // MARK: - 失敗の区分

    @Test func classifiesFailures() async throws {
        let limit = Self.result(
            output: nil, subtype: "error_during_execution", isError: true, text: "limit reached|1793782800", apiErrorStatus: 429
        )
        let cases: [(CommandResult, FailureClass)] = [
            (limit, .usageLimit),
            (Self.result(output: nil, isError: true, text: "API Error: 401 OAuth token has expired"), .authExpired),
            (Self.result(output: nil, isError: true, text: "API Error: 529 Overloaded", apiErrorStatus: 529), .claudeOutage),
            // 解除の時刻の無い 429 は、一時的な混み合い
            (Self.result(output: nil, isError: true, text: "API Error: 429 rate_limit_error", apiErrorStatus: 429), .claudeOutage),
            // 結果の JSON が成功でも、終了コードが 0 でなければ成功にしない
            (CommandResult(status: 1, standardOutput: Self.result().standardOutput, standardError: Data()), .unexpected),
            (CommandResult(status: 130, standardOutput: Data(), standardError: Data(), timedOut: true), .timeout),
            (CommandResult(status: 1, standardOutput: Data("not json".utf8), standardError: Data("panic \(Self.token)".utf8)), .unexpected)
        ]
        for (result, expected) in cases {
            let (reply, _) = await ask([result])
            guard case let .failed(failure, _) = reply else { Issue.record("\(expected): \(reply)"); continue }
            #expect(failure.failureClass == expected)
            #expect(!(failure.logExcerpt ?? "").contains(Self.token), "\(expected)")
        }
    }

    @Test func readsUsageLimitResetTime() {
        let zone = TimeZone(identifier: "Asia/Tokyo")!
        let now = Date(timeIntervalSince1970: 1_793_757_600) // 2026-11-04 の東京の 11:00
        let reset = UsageLimitReset(timeZone: zone, now: now)
        #expect(reset.date(in: "usage limit reached|1793782800") == Date(timeIntervalSince1970: 1_793_782_800))
        // 東京の 15:45 は 06:45Z
        #expect(reset.date(in: "You've hit your session limit · resets 3:45pm") == Date(timeIntervalSince1970: 1_793_774_700))
        // 過ぎた時刻は明日。時間帯が書いてあればそれで読む
        #expect(reset.date(in: "resets 9am (Asia/Tokyo)") == Date(timeIntervalSince1970: 1_793_836_800))
        #expect(reset.date(in: "resets 3pm (America/Los_Angeles)") == Date(timeIntervalSince1970: 1_793_833_200))
        #expect(reset.date(in: "limit reached") == nil)
    }
}
