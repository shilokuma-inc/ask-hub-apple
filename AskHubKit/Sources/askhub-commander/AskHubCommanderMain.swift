import AskHubCommander
import Foundation

/// 司令塔の実行ファイル。サブコマンドで動きを選ぶ
///
/// - `run`: 常駐のループを回す（LaunchAgent から起動する）
/// - `setup`: 設定を書き、トークンを Keychain に置き、最初の鍵を固定する（人が端末で流す）
/// - `apns`: APNs の鍵を Keychain に置き、鍵の id と Team ID を設定に足す（人が端末で流す）
/// - `git-credential`: git の credential helper（Keychain の GitHub のトークンを git に渡す）
/// - `launch-agent`: LaunchAgent の定義を書き、登録のコマンドを出す
/// - `check`: 設定と Keychain の様子を出す（秘密の値は出さない）
@main
enum AskHubCommanderMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "" : arguments.removeFirst()
        switch command {
        case "run": await run()
        case "setup": setup(arguments)
        case "apns": apns(arguments)
        case "git-credential": gitCredential(arguments)
        case "launch-agent": launchAgent()
        case "check": check()
        default: fail(usage, status: command.isEmpty || command == "help" ? EX_OK : EX_USAGE)
        }
    }

    static let usage = """
        使い方: askhub-commander <コマンド>
          setup --state-repo <owner/repo> --mac <名前> --claude <claude の絶対パス> --first-key <最初の鍵の id>
                --key-account <GitHub のアカウント> [--state-branch <ブランチ>] [--claude-capacity <数>]
          apns --key-id <APNs の鍵の id> --team-id <Team ID> --key-file <.p8 のパス> [--topic <Bundle ID>]
          launch-agent   LaunchAgent の定義を書き、登録のコマンドを出す
          run            常駐のループを回す
          check          設定と Keychain の様子を出す
        """

    static let paths = CommanderPaths()

    /// この実行ファイルの場所（シンボリックリンクを辿った先）
    static var executable: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    /// launchd の下では標準出力がファイルになり print はバッファに残るため、書いてすぐ出す
    @Sendable
    static func log(_ message: String) {
        let time = Date().formatted(.iso8601)
        FileHandle.standardOutput.write(Data("[\(time)] \(message)\n".utf8))
    }

    static func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("askhub-commander: \(message)\n".utf8))
        if status != EX_OK { log("終了します（終了コード \(status)）: \(message)") }
        exit(status)
    }
}
