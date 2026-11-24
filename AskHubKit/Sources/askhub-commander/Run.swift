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
        let releases = releaseWatch(runtime: runtime, context: context, transport: transport)
        // app-kit（public）は git で読む。版の中身はコミットで決まるので、1 つの部品を準備・広げる・ずれの点検で使い回す
        let (admin, appKit) = (runtime.adminTokens.map { AdminGitHub(tokens: $0, transport: transport) }, appKitSource(runtime))
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
            abandonedPullRequests: AbandonedPullRequests(
                context: context,
                github: GitHubPullRequestClosing(transport: transport, token: MachineRuntime.githubTokens(in: secrets)),
                log: log
            ),
            epicWorkspace: runtime.workspace,
            taskRunners: runtime.taskRunners(context: context, settings: TaskRepositorySettings.reader(context: context)),
            tidy: tidy(runtime: runtime, context: context),
            appIcons: appIcons(runtime: runtime, context: context),
            releases: releases,
            creative: creativeWatch(runtime: runtime, context: context, transport: transport),
            protection: protectionWatch(secrets: secrets, context: context, transport: transport),
            candidates: candidatesWatch(runtime: runtime, context: context, transport: transport),
            admin: admin,
            appKit: appKit,
            appKitPilot: configuration.appKitPilot ?? AppKitPolicy.defaultPilot,
            appKitWatch: appKitWatch(appKit: appKit, admin: admin, runtime: runtime, context: context, transport: transport),
            cleanup: runtime.cleanupService(context: context, log: log)
        )
        logStarted(configuration)
        await loop.run()
    }

    private static func logStarted(_ configuration: MachineConfiguration) {
        let pid = ProcessInfo.processInfo.processIdentifier
        log("起動しました（版 \(CommanderVersion.build.summary)、pid \(pid)、\(configuration.mac)、状態リポジトリ \(configuration.stateRepository)）")
    }

    private static func appKitSource(_ runtime: MachineRuntime) -> GitAppKitSource {
        GitAppKitSource(setup: .init(directory: runtime.paths.appKit), runner: ProcessCommandRunner())
    }

    /// 対象のアプリのアイコンは、常時オンの Mac の clone から取り出し、ビルドに使う Xcode の Icon Composer で書き出す
    private static func appIcons(runtime: MachineRuntime, context: CommanderContext) -> AppIconSync {
        AppIconSync(
            context: context,
            source: GitAppIconSource(
                workspace: runtime.workspace,
                renderer: AppIconRenderer(tools: runtime.configuration.buildTools(paths: runtime.paths), runner: ProcessCommandRunner())
            ),
            log: log
        )
    }

    /// 掛けた保護のずれの点検。自動で行うので、毎日のトークンで読むだけにする（管理用のトークンは人の意図の処理にだけ渡す）
    private static func protectionWatch(
        secrets: KeychainSecretStore,
        context: CommanderContext,
        transport: any HTTPTransport
    ) -> ProtectionWatch {
        ProtectionWatch(
            context: context,
            github: { GitHubPullRequests(repository: $0, transport: transport, token: MachineRuntime.githubTokens(in: secrets)) },
            log: log
        )
    }

    /// app-kit の見張り。ずれの点検は毎日のトークンで読むだけにし、版を広げるのは人の意図を受けた後だけ管理用のトークンで行う。
    /// 撮影の設定を作るときに読む App Store Connect のリファレンスデータは、アプリによらないので、最初の鍵で読む
    private static func appKitWatch(
        appKit: GitAppKitSource,
        admin: AdminGitHub?,
        runtime: MachineRuntime,
        context: CommanderContext,
        transport: any HTTPTransport
    ) -> AppKitWatch {
        let secrets = runtime.secrets
        var placementGroups: (@Sendable () async throws -> [AppStorePlacementProfileGroup])?
        if let configuration = runtime.configuration.appStoreConnect?.first {
            let store = AppStoreConnectClient(configuration: configuration, secrets: secrets, transport: transport)
            placementGroups = { @Sendable () async throws -> [AppStorePlacementProfileGroup] in try await store.placementProfileGroups() }
        }
        return AppKitWatch(
            context: context,
            source: appKit,
            github: { GitHubPullRequests(repository: $0, transport: transport, token: MachineRuntime.githubTokens(in: secrets)) },
            admin: admin,
            log: log,
            placementGroups: placementGroups
        )
    }

    /// 「対象に加える」の候補。自動で読むので、毎日のトークンで読むだけにする（管理用のトークンは人の意図の処理にだけ渡す）
    private static func candidatesWatch(
        runtime: MachineRuntime,
        context: CommanderContext,
        transport: any HTTPTransport
    ) -> RepositoryCandidatesWatch {
        let token = MachineRuntime.githubTokens(in: runtime.secrets)
        return RepositoryCandidatesWatch(
            context: context,
            owners: runtime.probe.owners,
            listing: { GitHubOwnerRepositories(owner: $0, transport: transport, token: token) },
            stateRepository: runtime.configuration.stateRepository,
            log: log
        )
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
            whatsNew: ClaudeWhatsNewDrafter(
                client: ClaudeClient(setup: runtime.claude, runner: ProcessCommandRunner()),
                sources: runtime.workspace
            ),
            listing: ClaudeListingDrafter(
                client: ClaudeClient(setup: runtime.claude, runner: ProcessCommandRunner()),
                sources: runtime.workspace
            ),
            rejections: ClaudeRejectionTriager(
                client: ClaudeClient(setup: runtime.claude, runner: ProcessCommandRunner()),
                sources: runtime.workspace
            ),
            // App Store のスクショは、ジョブと同じビルドの枠と Simulator の枠で撮る
            screenshots: MachineStoreScreenshots(
                pool: SimulatorPool(tools: runtime.configuration.buildTools(paths: runtime.paths), runner: ProcessCommandRunner()),
                slots: runtime.buildSlots,
                root: runtime.paths.root.appendingPathComponent("store-screenshots", isDirectory: true),
                log: log
            ),
            authors: GitHubCommitAuthors(token: token, log: log),
            log: log
        )
    }

    /// 生きている印を書いた後に片付けるもの（終わった epic の残りもの・残った Simulator・畳む epic）
    private static func tidy(runtime: MachineRuntime, context: CommanderContext) -> @Sendable () async -> Void {
        let cleanUp = runtime.finishedEpicCleanUp(context: context, log: log)
        let simulators = runtime.straySimulatorSweep(log: log)
        let archive = FinishedEpicArchive(context: context, log: log)
        return {
            await cleanUp.run()
            await simulators.run()
            await archive.run()
        }
    }

    /// クリエイティブアセットの案を、Claude が書き、各リポジトリの GitHub Actions で書き出すもの（元の画像はこの Mac に置く）
    private static func creativeWatch(runtime: MachineRuntime, context: CommanderContext, transport: any HTTPTransport) -> CreativeWatch {
        CreativeWatch(
            context: context,
            stores: (runtime.configuration.appStoreConnect ?? []).map { configuration in
                AppStoreConnectClient(configuration: configuration, secrets: runtime.secrets, transport: transport)
            },
            sources: runtime.workspace,
            hosting: GitHubReleaseHosting(transport: transport, token: MachineRuntime.githubTokens(in: runtime.secrets)),
            drafter: ClaudeCreativeDrafter(
                client: ClaudeClient(setup: runtime.claude, runner: ProcessCommandRunner()),
                sources: runtime.workspace
            ),
            originals: runtime.paths.root.appendingPathComponent("creative", isDirectory: true),
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
