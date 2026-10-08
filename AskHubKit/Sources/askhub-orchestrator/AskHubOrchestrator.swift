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
        let configPath = arguments.configPath ?? loader.defaultPath
        let configStore = FileOrchestratorConfigStore(path: configPath, loader: loader)
        let config: OrchestratorConfig
        do {
            config = try configStore.load()
        } catch {
            fail("\(error)", status: EX_CONFIG)
        }
        // launchd の下では標準出力がファイルになり print はバッファに残るため、log と同じ経路で書く
        log(summary(of: config))

        let token: String
        do {
            token = try githubToken()
        } catch {
            fail("GitHub のトークンを取得できません。`gh auth login` を済ませてください（\(error)）", status: EX_UNAVAILABLE)
        }
        // 起動に必要なもの（設定・トークン）が揃ってから、起動できたことを 1 行出す。
        // トークンの取得に失敗したときは fail の「終了します」の行だけが残り、成功と見分けられる
        log("起動しました（pid \(ProcessInfo.processInfo.processIdentifier)、設定: \(configPath)）")
        let client = GitHubClient(token: token)
        let orchestrator = Orchestrator(
            config: config,
            github: GitHubOrchestrator(client: client),
            inbox: GitHubInboxSource(client: client),
            // 起動スクリプトも同じ author だけを信用するよう、設定の値を環境変数で渡す
            runtime: LocalLoopRuntime(environment: [
                "ASKHUB_TRUSTED_AUTHORS": config.trustedAuthors.sortedLogins.joined(separator: ",")
            ]),
            log: log,
            // ポーリングのたびに設定を読み直し、担当リポジトリの作成・削除の依頼で書き換える
            configStore: configStore,
            // 担当リポジトリに書き込み権限を持つアカウントも信用する（設定の trustRepositoryWriters が有効なとき）
            repositoryWriters: RepositoryWriters(source: GitHubRepositoryWriters(client: client))
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
            "orgs: \(config.orgs.joined(separator: ", "))",
            "trusted authors: \(config.trustedAuthorLogins.joined(separator: ", "))"
                + (config.trustsRepositoryWriters ? "（ほかに担当リポジトリへの書き込み権限を持つアカウント）" : ""),
            "poll interval: \(config.pollInterval.components.seconds) 秒",
            "new repositories: \(config.repositoryCommands.newCheckoutDirectory)",
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
        // launchd の plist で標準エラーがログに向いていない環境でも理由が残るよう、ログと同じ経路（標準出力）にも時刻付きで書く
        log("終了します（終了コード \(status)）: \(message)")
        exit(status)
    }
}
