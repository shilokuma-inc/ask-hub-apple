import AskHubCommander
import Foundation

/// 司令塔の実行ファイル。サブコマンドで動きを選ぶ
///
/// - `run`: 常駐のループを回す（LaunchAgent から起動する）
/// - `setup`: 設定を書き、トークンを Keychain に置き、最初の鍵を固定する（人が端末で流す）
/// - `token`: 持ち主の GitHub のトークンを Keychain に入れ直す・足す（人が端末で流す）
/// - `admin-token`: 持ち主の管理用のトークンを Keychain に入れ直す・足す（人が端末で流す。保護の設定・対象に加えるときの準備に使う）
/// - `claude-token`: Claude の setup-token を Keychain に入れ直し、入れた日を記録する（人が端末で流す）
/// - `apns`: APNs の鍵を Keychain に置き、鍵の id と Team ID を設定に足す（人が端末で流す）
/// - `app-store-connect`: App Store Connect の API キーを Keychain に置き、鍵の id と Issuer ID を設定に足す（人が端末で流す）
/// - `xcode`: ビルドとテストに使う Xcode を設定で決める・xcode-select で選んだものに戻す（人が端末で流す）
/// - `git-credential`: git の credential helper（リポジトリの持ち主の GitHub のトークンを Keychain から git に渡す）
/// - `launch-agent`: LaunchAgent の定義を書き、登録のコマンドを出す
/// - `check`: 版と互換の番号・設定と Keychain の様子・トークンの期限を出す（秘密の値は出さない）
/// - `version`: 版・コミット・互換の番号を出す（Keychain を読まないので、ssh のセッションからも流せる）
@main
enum AskHubCommanderMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "" : arguments.removeFirst()
        // トークンを端末で伏せて入れてもらうコマンドと、鍵（APNs・App Store Connect）を Keychain に置くコマンドは、同じ形なので一覧から選ぶ
        if let store = tokenCommands[command] { return store(arguments) }
        if let register = keyCommands[command] { return register(arguments) }
        switch command {
        case "run": await run()
        case "setup": setup(arguments)
        case "xcode": await commandLine.xcode(arguments)
        case "git-credential": commandLine.gitCredential(arguments)
        case "launch-agent": commandLine.launchAgent()
        case "check", "version": await check(versionOnly: command == "version")
        default: commandLine.fail(usage, status: command.isEmpty || command == "help" ? EX_OK : EX_USAGE)
        }
    }

    /// トークンを端末で伏せて入れてもらい、Keychain に置くコマンド
    static let tokenCommands: [String: @Sendable ([String]) -> Void] = [
        "token": { commandLine.token($0) },
        "admin-token": { commandLine.adminToken($0) },
        "claude-token": { commandLine.replaceClaudeToken($0) }
    ]

    /// 鍵（.p8）を Keychain に置き、鍵の id を設定に足すコマンド
    static let keyCommands: [String: @Sendable ([String]) -> Void] = [
        "apns": { apns($0) },
        "app-store-connect": { appStoreConnect($0) }
    ]

    static let usage = """
        使い方: askhub-commander <コマンド>
          setup --state-repo <owner/repo> --mac <名前> --claude <claude の絶対パス> --first-key <最初の鍵の id>
                --key-account <GitHub のアカウント> [--github-owner <対象のリポジトリの持ち主> ...]
                [--state-branch <ブランチ>] [--claude-capacity <数>]
          token <持ち主>  持ち主（organization・個人）の GitHub の fine-grained token を入れ直す・足す
          admin-token <持ち主>  持ち主の管理用の fine-grained token（保護の設定・対象に加えるときの準備に使う）を入れ直す・足す
          claude-token   Claude の setup-token を入れ直す（入れた日から 1 年を期限として記録する）
          apns --key-id <APNs の鍵の id> --team-id <Team ID> --key-file <.p8 のパス> [--topic <Bundle ID>]
          app-store-connect --key-id <API キーの id> --issuer-id <Issuer ID> --key-file <.p8 のパス>
                         配信を見つける App Store Connect の API キーを足す（Apple のチームごとに 1 つ。役割は App Manager）
          xcode <Xcode.app のパス>  ビルドとテストに使う Xcode を決める（--unset で xcode-select で選んだものに戻す）
          launch-agent   LaunchAgent の定義を書き、登録のコマンドを出す
          run            常駐のループを回す
          check          版と互換の番号・設定と Keychain の様子・トークンの期限を出す
          version        版・コミット・互換の番号を出す
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
