import AskHubClaude
import AskHubCommander
import AskHubCommands
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

extension AskHubCommanderMain {
    /// 常駐のループを組み立てて回す
    static func run() async {
        let runtime = await MachineRuntime.load(commandLine, budget: .commander)
        let configuration = runtime.configuration
        // 状態リポジトリと Discussion の写しは、同じアカウントの内容を作る要求の上限を分け合うので、司令塔の書き込みの予算を 1 つにする。
        // Discussion は、対象のリポジトリの持ち主のトークンで読み書きする（トークンは持ち主ごとにある）
        let transport = GitHubURLSessionTransport()
        let (budget, secrets) = (runtime.budget, runtime.secrets)
        let discussions: @Sendable (RepositoryFullName) -> any DiscussionAPI = { repo in
            GitHubDiscussions(transport: transport, budget: budget, token: MachineRuntime.githubToken(for: repo.owner, in: secrets))
        }
        // 人の意図の処理・Claude のジョブの結果・通知の記録・写しの id の書き戻しは、同じ排他を使うよう、同じ `context` を渡す
        let context = CommanderContext(store: runtime.store, mac: configuration.mac)
        let cleanUp = runtime.finishedEpicCleanUp(context: context, log: log)
        let loop = CommanderLoop(
            context: context,
            settings: .init(
                capacity: configuration.capacity, commanderVersion: CommanderVersion.current, claudeVersion: runtime.claudeVersion
            ),
            verifier: { () throws(CommanderError) in try await runtime.trusted.verifier() },
            client: ClaudeClient(setup: runtime.claude, runner: ProcessCommandRunner()),
            workspace: runtime.workspace,
            status: { await runtime.probe.status() },
            notifier: notifier(configuration.apns, secrets: runtime.secrets, context: context),
            log: log,
            mirror: DiscussionMirror(context: context, discussions: discussions, log: log),
            epicWorkspace: runtime.workspace,
            taskRunners: runtime.taskRunners(context: context, settings: TaskRepositorySettings.reader(context: context)),
            tidy: { await cleanUp.run() }
        )
        log("起動しました（pid \(ProcessInfo.processInfo.processIdentifier)、\(configuration.mac)、状態リポジトリ \(configuration.stateRepository)）")
        await loop.run()
    }

    /// 進行を止めるものを知らせるもの。APNs の設定が無ければ nil（知らせない）
    private static func notifier(_ apns: APNsConfiguration?, secrets: KeychainSecretStore, context: CommanderContext) -> Notifier? {
        guard let apns else {
            log("APNs の設定が無いので、通知を送らない（askhub-commander apns で登録する）")
            return nil
        }
        let state = APNsKey.state(in: secrets)
        if state != .ok { log("Keychain の APNs の鍵が \(state.rawValue)。通知は送れずに待つ（askhub-commander apns で登録し直す）") }
        return Notifier(context: context, sender: APNsSender(configuration: apns, secrets: secrets), log: log)
    }
}
