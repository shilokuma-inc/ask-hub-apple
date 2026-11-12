#if os(macOS)
import AskHubBuild
import AskHubClaude
import AskHubCommands
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 司令塔とワーカーの `run` が共通に組み立てるもの（状態リポジトリ・公開鍵の一覧・作業場所・Claude・この Mac の様子）
public struct MachineRuntime: Sendable {
    public var configuration: MachineConfiguration
    public var paths: MachinePaths
    public var secrets: KeychainSecretStore
    /// 状態リポジトリへの書き込みの予算。同じアカウントの内容を作る要求の上限を分け合うので、書き手ごとに 1 つ
    public var budget: WriteBudget
    public var store: GitHubContentsStore
    public var trusted: TrustedKeys
    public var probe: MachineProbe
    public var workspace: GitRepositoryWorkspace
    public var claude: ClaudeSetup
    /// `claude --version` の版（生きている印に書く）。分からなければ nil
    public var claudeVersion: String?
    /// 管理用のトークン（司令塔だけ。ワーカーは nil）。署名した人の意図の処理にだけ渡す
    public var adminTokens: AdminTokens?
    /// epic の作業場所の排他。ジョブ（`taskRunners`）と、終わった epic の残りものの片付け（`finishedEpicCleanUp`）で同じものを使う
    public var epicLocks = EpicLocks()

    /// 設定と Keychain から組み立てる。設定や Claude の setup-token が無ければ止める
    public static func load(_ commandLine: MachineCommandLine, budget limits: WriteBudget.Limits) async -> Self {
        let configuration = commandLine.loadConfiguration()
        let claudeToken = commandLine.claudeToken()
        let paths = commandLine.paths
        for directory in paths.directories {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let secrets = commandLine.secrets
        let budget = WriteBudget(limits: limits)
        let store = GitHubContentsStore(
            repository: configuration.stateRepository,
            branch: configuration.stateBranch,
            budget: budget,
            token: githubToken(for: configuration.stateRepository.owner, in: secrets)
        )
        let tools = configuration.buildTools(paths: paths)
        await logXcode(configuration, tools: tools)
        let claude = ClaudeSetup(
            executable: URL(fileURLWithPath: configuration.claude),
            configDirectory: paths.claudeConfig,
            homeDirectory: paths.claudeHome,
            temporaryDirectory: paths.claudeTemporary,
            oauthToken: claudeToken
        )
        return Self(
            configuration: configuration,
            paths: paths,
            secrets: secrets,
            budget: budget,
            store: store,
            trusted: TrustedKeys(
                anchor: TrustAnchor(store: secrets), store: store, accounts: Set(configuration.keyAccounts), log: MachineCommandLine.log
            ),
            probe: probe(commandLine, configuration: configuration, claude: claude, tools: tools),
            workspace: GitRepositoryWorkspace(
                setup: .init(root: paths.work, credentialHelper: GitCredential.helper(executable: commandLine.executable)),
                runner: ProcessCommandRunner(),
                authors: GitHubCommitAuthors(token: githubTokens(in: secrets), log: MachineCommandLine.log)
            ),
            claude: claude,
            claudeVersion: await version(of: claude),
            // 管理用のトークンは常時オンの Mac の司令塔にだけ置く
            adminTokens: commandLine.role == .commander ? AdminTokens(secrets: secrets) : nil
        )
    }

    /// 生きている印に書く様子を測るもの。管理用のトークンは司令塔だけが確かめる（ワーカーは自己診断にも書かない）
    private static func probe(
        _ commandLine: MachineCommandLine,
        configuration: MachineConfiguration,
        claude: ClaudeSetup,
        tools: BuildTools
    ) -> MachineProbe {
        let paths = commandLine.paths
        var probe = MachineProbe(
            secrets: commandLine.secrets,
            volume: paths.root,
            owners: configuration.tokenOwnersReloading(from: paths.configuration, role: commandLine.role),
            githubExpiry: GitHubTokenExpiry(),
            claudeTokenRecord: paths.claudeTokenRecord,
            claudeVersion: { await version(of: claude) },
            xcodeVersion: { await tools.xcodeVersion(runner: ProcessCommandRunner()) }
        )
        if commandLine.role == .commander {
            probe.adminOwners = configuration.adminOwnersReloading(from: paths.configuration, role: commandLine.role)
            probe.adminExpiry = GitHubTokenExpiry()
        }
        return probe
    }

    /// 持ち主の GitHub のトークンを、要求のたびに Keychain から読む（`token` で入れ直したら、次の要求から使う）
    public static func githubToken(for owner: String, in secrets: KeychainSecretStore) -> @Sendable () async throws -> String {
        {
            guard let token = try GitHubTokens(secrets: secrets).token(for: owner) else { throw StateStoreError.tokenUnavailable }
            return token
        }
    }

    /// リポジトリの持ち主を受け取り、その持ち主の GitHub のトークンを Keychain から読む（`AskHubPullRequests` に渡す形）
    public static func githubTokens(in secrets: KeychainSecretStore) -> @Sendable (_ owner: String) async throws -> String {
        { owner in try await githubToken(for: owner, in: secrets)() }
    }

    /// ビルドとテストに使う Xcode をログに出す。決めた Xcode が無ければ、その理由も出す（ビルドの前にも止める）
    private static func logXcode(_ configuration: MachineConfiguration, tools: BuildTools) async {
        if let problem = tools.developerDirectoryProblem {
            MachineCommandLine.log(problem)
            return
        }
        let version = await tools.xcodeVersion(runner: ProcessCommandRunner()).map { "Xcode \($0)" } ?? "版を読めない"
        let xcode = configuration.xcode ?? "設定で決めていない。xcode-select で選んだもの"
        MachineCommandLine.log("ビルドとテストに使う Xcode: \(xcode)（\(version)）")
    }

    /// `claude --version` の版。分からなければ nil。生きている印を書くたびに測るので、ここでも自分で更新させない
    private static func version(of claude: ClaudeSetup) async -> String? {
        let command = Command(
            executable: claude.executable,
            arguments: ["--version"],
            environment: [
                "HOME": claude.homeDirectory.path,
                "PATH": claude.path,
                "CLAUDE_CONFIG_DIR": claude.configDirectory.path,
                "DISABLE_AUTOUPDATER": "1"
            ],
            workingDirectory: claude.temporaryDirectory,
            timeout: .seconds(30)
        )
        guard let result = try? await ProcessCommandRunner().run(command), result.succeeded else { return nil }
        return String(bytes: result.standardOutput, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}
#endif
