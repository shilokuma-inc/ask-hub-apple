import AskHubCommander
import AskHubProtocol
import AskHubWorker
import Foundation

/// ワーカーの実行ファイル。開始のときに人が選んだ Mac で、自分宛てのジョブを引き受けて動かす（`docs/renewal/operations.md`）
///
/// - `setup`: 設定を書き、トークンを Keychain に置き、最初の鍵を固定する（人が端末で流す）
/// - `token`: 持ち主の GitHub のトークンを Keychain に入れ直す・足す（人が端末で流す）
/// - `claude-token`: Claude の setup-token を Keychain に入れ直し、入れた日を記録する（人が端末で流す）
/// - `xcode`: ビルドとテストに使う Xcode を設定で決める・xcode-select で選んだものに戻す（人が端末で流す）
/// - `run`: 常駐のループを回す。常駐できる Mac は LaunchAgent から、できない Mac（社用の MacBook など）はターミナルで流し続ける
/// - `launch-agent`: 常駐できる Mac で、LaunchAgent の定義を書き、登録のコマンドを出す
/// - `git-credential`: git の credential helper（リポジトリの持ち主の GitHub のトークンを Keychain から git に渡す）
/// - `check`: 設定と Keychain の様子・トークンの期限を出す（秘密の値は出さない）
///
/// ssh のセッションからは Keychain を読めないので、ログインしている Mac の端末か LaunchAgent から起動する
@main
enum AskHubWorkerMain {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.isEmpty ? "" : arguments.removeFirst()
        switch command {
        case "run": await run()
        case "setup": setup(arguments)
        case "token": commandLine.token(arguments)
        case "claude-token": commandLine.replaceClaudeToken(arguments)
        case "xcode": await commandLine.xcode(arguments)
        case "git-credential": commandLine.gitCredential(arguments)
        case "launch-agent": launchAgent()
        case "check": print(await commandLine.checkLines(version: CommanderVersion.current).joined(separator: "\n"))
        default: commandLine.fail(usage, status: command.isEmpty || command == "help" ? EX_OK : EX_USAGE)
        }
    }

    static let usage = """
        使い方: askhub-worker <コマンド>
          setup --state-repo <owner/repo> --mac <名前> --kind resident|manual --claude <claude の絶対パス>
                --first-key <最初の鍵の id> --key-account <GitHub のアカウント> [--github-owner <対象のリポジトリの持ち主> ...]
                [--state-branch <ブランチ>] [--claude-capacity <数>] [--build-capacity <数>]
                （--kind は、LaunchAgent で常駐できる Mac なら resident、できない Mac なら manual）
          token <持ち主>  持ち主（organization・個人）の GitHub の fine-grained token を入れ直す・足す
          claude-token   Claude の setup-token を入れ直す（入れた日から 1 年を期限として記録する）
          xcode <Xcode.app のパス>  ビルドとテストに使う Xcode を決める（--unset で xcode-select で選んだものに戻す）
          run            ジョブを引き受けて動かし続ける（常駐できない Mac では、ターミナルで流したままにする）
          launch-agent   常駐できる Mac で、LaunchAgent の定義を書き、登録のコマンドを出す
          check          設定と Keychain の様子・トークンの期限を出す
        """

    static let commandLine = MachineCommandLine(role: .worker, executable: MachineCommandLine.currentExecutable)

    @Sendable
    static func log(_ message: String) {
        MachineCommandLine.log(message)
    }

    /// 設定を書き、トークンを Keychain に置き、最初の鍵を固定する。次にすることを Mac の種類ごとに出す
    static func setup(_ arguments: [String]) {
        commandLine.setup(arguments, usage: usage)
        switch commandLine.loadConfiguration().kind {
        case .resident:
            print("次に launch-agent で常駐の定義を書き、出てくるコマンドで登録してください")
        default:
            print("常駐できない Mac では、ターミナルで次のコマンドを流したままにしてください（再起動・ログアウトの後は、もう一度流す）:\n  '\(commandLine.executable.path)' run")
        }
    }

    /// 常駐できる Mac でだけ、LaunchAgent の定義を書く
    static func launchAgent() {
        guard commandLine.loadConfiguration().kind == .resident else {
            commandLine.fail("常駐できない Mac（--kind manual）では LaunchAgent を使わない。ターミナルで run を流したままにする", status: EX_USAGE)
        }
        commandLine.launchAgent()
    }

    /// 常駐のループを組み立てて回す
    static func run() async {
        let runtime = await MachineRuntime.load(commandLine, budget: .worker)
        let configuration = runtime.configuration
        let context = CommanderContext(store: runtime.store, mac: configuration.mac)
        let settings = WorkerLoop.Settings(
            kind: configuration.kind,
            capacity: configuration.capacity,
            workerVersion: CommanderVersion.current,
            claudeVersion: runtime.claudeVersion
        )
        // 作業場所の用意と、タスクのジョブ（実装・子 PR のレビュー・直し）を引き受ける
        var runners = runtime.taskRunners(context: context, settings: TaskRepositorySettings.reader(context: context))
        runners[.prepareWorkspace] = PrepareWorkspaceRunner(context: context, workspace: runtime.workspace)
        let cleanUp = runtime.finishedEpicCleanUp(context: context, log: log)
        let loop = WorkerLoop(
            context: context,
            settings: settings,
            verifier: { () throws(CommanderError) in try await runtime.trusted.verifier() },
            runners: runners,
            status: { await runtime.probe.status() },
            tidy: {
                await runtime.workspace.tidy()
                await cleanUp.run()
            },
            log: log
        )
        let kind = configuration.kind.rawValue
        let pid = ProcessInfo.processInfo.processIdentifier
        log("起動しました（pid \(pid)、\(configuration.mac)、\(kind)、状態リポジトリ \(configuration.stateRepository)）")
        if configuration.kind == .manual {
            log("このターミナルを開いたままにしてください。止めるときは Control-C（動いていた試行は、もう一度 run を流すと続きから試します）")
        }
        await loop.run()
    }
}
