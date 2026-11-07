import AskHubCommander
import Foundation

/// 司令塔の実行ファイル。サブコマンドで動きを選ぶ
///
/// - `run`: 常駐のループを回す（LaunchAgent から起動する）
/// - `setup`: 設定を書き、トークンを Keychain に置き、最初の鍵を固定する（人が端末で流す）
/// - `token`: 持ち主の GitHub のトークンを Keychain に入れ直す・足す（人が端末で流す）
/// - `apns`: APNs の鍵を Keychain に置き、鍵の id と Team ID を設定に足す（人が端末で流す）
/// - `git-credential`: git の credential helper（リポジトリの持ち主の GitHub のトークンを Keychain から git に渡す）
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
        case "token": commandLine.token(arguments)
        case "apns": apns(arguments)
        case "git-credential": commandLine.gitCredential(arguments)
        case "launch-agent": commandLine.launchAgent()
        case "check": check()
        default: commandLine.fail(usage, status: command.isEmpty || command == "help" ? EX_OK : EX_USAGE)
        }
    }

    static let usage = """
        使い方: askhub-commander <コマンド>
          setup --state-repo <owner/repo> --mac <名前> --claude <claude の絶対パス> --first-key <最初の鍵の id>
                --key-account <GitHub のアカウント> [--github-owner <対象のリポジトリの持ち主> ...]
                [--state-branch <ブランチ>] [--claude-capacity <数>]
          token <持ち主>  持ち主（organization・個人）の GitHub の fine-grained token を入れ直す・足す
          apns --key-id <APNs の鍵の id> --team-id <Team ID> --key-file <.p8 のパス> [--topic <Bundle ID>]
          launch-agent   LaunchAgent の定義を書き、登録のコマンドを出す
          run            常駐のループを回す
          check          設定と Keychain の様子を出す
        """

    static let commandLine = MachineCommandLine(role: .commander, executable: MachineCommandLine.currentExecutable)

    static var paths: MachinePaths { commandLine.paths }

    @Sendable
    static func log(_ message: String) {
        MachineCommandLine.log(message)
    }

    static func fail(_ message: String, status: Int32) -> Never {
        commandLine.fail(message, status: status)
    }
}
