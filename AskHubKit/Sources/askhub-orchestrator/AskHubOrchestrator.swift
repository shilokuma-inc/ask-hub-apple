import AskHubKit
import Foundation
import OrchestratorKit

/// オーケストレーターのエントリポイント。
/// 設定を読み込んで内容を表示し、`pollInterval` ごとに GitHub をポーリングする
@main
enum AskHubOrchestrator {
    static func main() async {
        let arguments: OrchestratorArguments
        do {
            arguments = try OrchestratorArguments.parse(CommandLine.arguments.dropFirst())
        } catch {
            fail("\(error)\n\n\(OrchestratorArguments.usage)", status: EX_USAGE)
        }
        if arguments.showsHelp {
            print(OrchestratorArguments.usage)
            return
        }

        let loader = OrchestratorConfigLoader()
        let config: OrchestratorConfig
        do {
            config = try loader.load(from: arguments.configPath ?? loader.defaultPath)
        } catch {
            fail("\(error)", status: EX_CONFIG)
        }
        print(summary(of: config))

        let token: String
        do {
            token = try githubToken()
        } catch {
            fail("GitHub のトークンを取得できません。`gh auth login` を済ませてください（\(error)）", status: EX_UNAVAILABLE)
        }
        let client = GitHubClient(token: token)
        let orchestrator = Orchestrator(
            config: config,
            github: GitHubOrchestrator(client: client),
            inbox: GitHubInboxSource(client: client),
            runtime: LocalLoopRuntime(),
            log: log
        )
        if arguments.runsOnce {
            do {
                try await orchestrator.pollOnce()
            } catch {
                fail("ポーリングに失敗しました: \(error)", status: EX_TEMPFAIL)
            }
            return
        }
        await orchestrator.run()
    }

    /// `gh auth token` でトークンを得る（Discussion #1 の Q4）。トークンはメモリにだけ置き、表示しない
    private static func githubToken() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "auth", "token"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let token = String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw TokenError(status: process.terminationStatus)
        }
        return token
    }

    private struct TokenError: Error, CustomStringConvertible {
        let status: Int32

        var description: String {
            "gh auth token の終了コード: \(status)"
        }
    }

    /// 時刻を付けて標準出力に書く。launchd のログに残るよう、バッファせずに書き出す
    @Sendable
    private static func log(_ message: String) {
        let time = Date().formatted(.iso8601)
        FileHandle.standardOutput.write(Data("[\(time)] \(message)\n".utf8))
    }

    private static func summary(of config: OrchestratorConfig) -> String {
        var lines = [
            "org: \(config.org)",
            "trusted authors: \(config.trustedAuthorLogins.joined(separator: ", "))",
            "poll interval: \(config.pollInterval.components.seconds) 秒",
            "repositories:"
        ]
        for repository in config.repositories {
            lines.append("  - \(repository.fullName)")
            lines.append("      checkout: \(repository.checkoutPath)")
            lines.append("      control:  \(repository.controlWorktreePath)")
            lines.append("      loop:     \(jsonArray(config.loopCommand.render(for: repository)))")
        }
        return lines.joined(separator: "\n")
    }

    /// 空白を含む引数でも境界が分かるよう、JSON の配列として表示する
    private static func jsonArray(_ arguments: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(arguments), let json = String(bytes: data, encoding: .utf8) else {
            return arguments.description
        }
        return json
    }

    private static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("askhub-orchestrator: \(message)\n".utf8))
        exit(status)
    }
}
