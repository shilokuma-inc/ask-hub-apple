import AskHubBuild
import AskHubClaude
import AskHubCommander
import AskHubCommands
import AskHubKeychain
import AskHubProtocol
import AskHubPullRequests
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
        // 対象のアプリのアイコンは、常時オンの Mac の clone から取り出し、ビルドに使う Xcode の Icon Composer で書き出す
        let appIcons = AppIconSync(
            context: context,
            source: GitAppIconSource(
                workspace: runtime.workspace,
                renderer: AppIconRenderer(tools: configuration.buildTools(paths: runtime.paths), runner: ProcessCommandRunner())
            ),
            log: log
        )
        let releases = releaseWatch(runtime: runtime, context: context, transport: transport)
        let loop = CommanderLoop(
            context: context,
            settings: .init(
                capacity: configuration.capacity, commanderVersion: CommanderVersion.current, claudeVersion: runtime.claudeVersion
            ),
            verifier: { () throws(CommanderError) in try await runtime.trusted.verifier() },
            client: ClaudeClient(setup: runtime.claude, runner: ProcessCommandRunner()),
            workspace: runtime.workspace,
            status: { await runtime.probe.status() },
            rateLimit: { await runtime.probe.githubRateLimit() },
            notifier: notifier(configuration.apns, secrets: runtime.secrets, context: context),
            log: log,
            mirror: DiscussionMirror(context: context, discussions: discussions, log: log),
            epicWorkspace: runtime.workspace,
            taskRunners: runtime.taskRunners(context: context, settings: TaskRepositorySettings.reader(context: context)),
            tidy: { await cleanUp.run() },
            appIcons: appIcons,
            releases: releases,
            // ずれの点検は自動で行うので、毎日のトークンで読むだけにする。管理用のトークンは人の意図の処理にだけ渡す
            protection: ProtectionWatch(
                context: context,
                github: { GitHubPullRequests(repository: $0, transport: transport, token: MachineRuntime.githubTokens(in: secrets)) },
                log: log
            ),
            admin: runtime.adminTokens.map { AdminGitHub(tokens: $0, transport: transport) }
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        log("起動しました（版 \(CommanderVersion.build.summary)、pid \(pid)、\(configuration.mac)、状態リポジトリ \(configuration.stateRepository)）")
        await loop.run()
    }

    /// App Store での配信を見つけ、リリースの後作業を進めるもの。App Store Connect の鍵の設定が無ければ、配信は見つけず、
    /// 前に見つけた版の後作業だけを進める
    private static func releaseWatch(runtime: MachineRuntime, context: CommanderContext, transport: any HTTPTransport) -> ReleaseWatch {
        let stores = (runtime.configuration.appStoreConnect ?? []).map { configuration in
            AppStoreConnectClient(configuration: configuration, secrets: runtime.secrets, transport: transport)
        }
        if stores.isEmpty { log("App Store Connect の鍵の設定が無いので、配信を見つけない（askhub-commander app-store-connect で登録する）") }
        for store in runtime.configuration.appStoreConnect ?? [] {
            let state = AppStoreConnectKey.state(of: store, in: runtime.secrets)
            if state != .ok {
                log("Keychain の App Store Connect の鍵 \(store.keyId) が \(state.rawValue)。配信は見つけられずに待つ（app-store-connect で登録し直す）")
            }
        }
        let token = MachineRuntime.githubTokens(in: runtime.secrets)
        return ReleaseWatch(
            context: context,
            stores: stores,
            sources: runtime.workspace,
            hosting: GitHubReleaseHosting(transport: transport, token: token),
            drafter: ClaudeReleaseNotesDrafter(
                client: ClaudeClient(setup: runtime.claude, runner: ProcessCommandRunner()),
                sources: runtime.workspace
            ),
            authors: GitHubCommitAuthors(token: token, log: log),
            log: log
        )
    }

    /// 進行を止めるものを知らせるもの。APNs の設定が無ければ nil（知らせない）
    private static func notifier(_ apns: APNsConfiguration?, secrets: KeychainSecretStore, context: CommanderContext) -> Notifier? {
        guard let apns else {
            log("APNs の設定が無いので、通知を送らない（askhub-commander apns で登録する）")
            return nil
        }
        let state = APNsKey.state(in: secrets)
        if state != .ok { log("Keychain の APNs の鍵が \(state.rawValue)。通知は送れずに待つ（askhub-commander apns で登録し直す）") }
        return Notifier(context: context, sender: APNsSender(configuration: apns, secrets: secrets, log: log), log: log)
    }
}
