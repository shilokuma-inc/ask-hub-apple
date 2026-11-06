import AskHubClaude
import AskHubCommander
import AskHubCommands
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

extension AskHubCommanderMain {
    static var secrets: KeychainSecretStore { KeychainSecretStore(service: CommanderPaths.keychainService) }

    /// 常駐のループを組み立てて回す
    static func run() async {
        let configuration: CommanderConfiguration
        do {
            configuration = try CommanderConfiguration.load(from: paths.configuration)
        } catch {
            fail("設定（\(paths.configuration.path)）を読めない。setup を流す（\(error.localizedDescription)）", status: EX_CONFIG)
        }
        let secrets = secrets
        guard let claudeToken = try? secrets.read(.claudeToken).flatMap({ String(bytes: $0, encoding: .utf8) }),
              claudeToken.hasPrefix(MachineProbe.claudeTokenPrefix) else {
            fail("Keychain に Claude の setup-token が無い・形が違う。setup を流す", status: EX_CONFIG)
        }
        for directory in [paths.work, paths.claudeConfig, paths.claudeHome, paths.claudeTemporary, paths.logs] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let store = GitHubContentsStore(
            repository: configuration.stateRepository,
            branch: configuration.stateBranch,
            budget: WriteBudget(limits: .commander)
        ) {
            guard let data = try secrets.read(.githubToken), let token = String(bytes: data, encoding: .utf8), !token.isEmpty else {
                throw StateStoreError.tokenUnavailable
            }
            return token
        }
        let claude = ClaudeSetup(
            executable: URL(fileURLWithPath: configuration.claude),
            configDirectory: paths.claudeConfig,
            homeDirectory: paths.claudeHome,
            temporaryDirectory: paths.claudeTemporary,
            oauthToken: claudeToken
        )
        let loop = makeLoop(configuration: configuration, store: store, claude: claude, claudeVersion: await version(of: claude))
        log("起動しました（pid \(ProcessInfo.processInfo.processIdentifier)、\(configuration.mac)、状態リポジトリ \(configuration.stateRepository)）")
        await loop.run()
    }

    private static func makeLoop(
        configuration: CommanderConfiguration,
        store: GitHubContentsStore,
        claude: ClaudeSetup,
        claudeVersion: String?
    ) -> CommanderLoop {
        let secrets = secrets
        let trusted = TrustedKeys(anchor: TrustAnchor(store: secrets), store: store, accounts: Set(configuration.keyAccounts), log: log)
        let probe = MachineProbe(secrets: secrets, volume: paths.root)
        let workspace = GitRepositoryWorkspace(
            setup: .init(root: paths.work, credentialHelper: GitCredential.helper(executable: executable)),
            runner: ProcessCommandRunner()
        )
        return CommanderLoop(
            context: CommanderContext(store: store, mac: configuration.mac),
            settings: .init(capacity: configuration.capacity, commanderVersion: CommanderVersion.current, claudeVersion: claudeVersion),
            verifier: { () throws(CommanderError) in try await trusted.verifier() },
            client: ClaudeClient(setup: claude, runner: ProcessCommandRunner()),
            workspace: workspace,
            status: { probe.status() },
            log: log
        )
    }

    /// `claude --version` の版（生きている印に書く）。分からなければ nil
    private static func version(of claude: ClaudeSetup) async -> String? {
        let command = Command(
            executable: claude.executable,
            arguments: ["--version"],
            environment: ["HOME": claude.homeDirectory.path, "PATH": claude.path, "CLAUDE_CONFIG_DIR": claude.configDirectory.path],
            workingDirectory: claude.temporaryDirectory,
            timeout: .seconds(30)
        )
        guard let result = try? await ProcessCommandRunner().run(command), result.succeeded else { return nil }
        return String(bytes: result.standardOutput, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }
}
