import Foundation
import OrchestratorKit

/// オーケストレーターのエントリポイント。
/// 現時点では設定を読み込んで内容を表示する。ポーリングと各アクションは後続のタスクで追加する
@main
enum AskHubOrchestrator {
    static func main() {
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
