#if os(macOS)
@testable import AskHubCommands
import Darwin
import Foundation
import Testing

struct ProcessCommandRunnerTests {
    private let runner = ProcessCommandRunner()

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func shell(
        _ script: String,
        in directory: URL,
        environment: [String: String] = [:],
        timeout: Duration = .seconds(30)
    ) -> Command {
        Command(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: environment,
            workingDirectory: directory,
            timeout: timeout,
            interruptGrace: .seconds(1),
            terminateGrace: .seconds(1)
        )
    }

    /// 条件がそろうまで待つ（負荷の高い CI でも揺らがないよう、長めに待つ）
    private func waitUntil(seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @Test func collectsOutputsSeparatelyAndExitStatus() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await runner.run(shell("echo out; echo err >&2; exit 3", in: directory))
        #expect(result.status == 3)
        #expect(!result.succeeded)
        #expect(String(bytes: result.standardOutput, encoding: .utf8) == "out\n")
        #expect(String(bytes: result.standardError, encoding: .utf8) == "err\n")
        #expect(!result.timedOut)
    }

    @Test func passesOnlyGivenEnvironmentAndEmptyInput() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 親の環境変数（HOME・PATH など）は渡らない。標準入力は空なので cat はすぐ終わる
        let result = try await runner.run(shell("/usr/bin/env; /bin/cat; pwd -P", in: directory, environment: ["ONLY": "1"]))
        let lines = (String(bytes: result.standardOutput, encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        #expect(lines.contains("ONLY=1"))
        #expect(!lines.contains { $0.hasPrefix("HOME=") || $0.hasPrefix("GITHUB_TOKEN=") })
        // /var は /private/var への別名なので、フォルダの名前で比べる
        #expect(lines.last?.hasSuffix("/" + directory.lastPathComponent) == true)
        #expect(result.succeeded)
    }

    @Test func stopsCommandAndDescendantsAfterTimeout() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 子の sleep は SIGINT と SIGTERM を無視する。最後の SIGKILL で止まる
        let script = "(trap '' INT TERM; sleep 60) & echo $! > child.pid; wait"
        let result = try await runner.run(shell(script, in: directory, timeout: .seconds(3)))
        #expect(result.timedOut)
        let text = try String(contentsOf: directory.appendingPathComponent("child.pid"), encoding: .utf8)
        let child = try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await waitUntil { kill(child, 0) != 0 })
    }

    @Test func interruptLetsCommandFinishWithoutWaitingForGrace() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // SIGINT で後片付けして終わるコマンドは、SIGTERM の猶予まで待たない
        var command = shell("trap 'echo cleaned; exit 0' INT; while true; do sleep 0.1; done", in: directory, timeout: .seconds(2))
        command.interruptGrace = .seconds(20)
        command.terminateGrace = .seconds(20)
        let started = ContinuousClock.now
        let result = try await runner.run(command)
        #expect(result.timedOut)
        #expect(String(bytes: result.standardOutput, encoding: .utf8)?.contains("cleaned") == true)
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func descriptionHidesEnvironmentValues() throws {
        let command = shell("true", in: URL(fileURLWithPath: "/tmp"), environment: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-secret"])
        #expect(!"\(command)".contains("sk-ant-oat01-secret"))
        #expect("\(command)".contains("CLAUDE_CODE_OAUTH_TOKEN"))
    }
}
#endif
