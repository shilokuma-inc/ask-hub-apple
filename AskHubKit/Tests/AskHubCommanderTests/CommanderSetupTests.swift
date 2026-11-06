@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 司令塔の実行ファイルの部品（設定・セットアップの引数・credential helper・LaunchAgent・公開鍵の一覧・自己診断）
struct CommanderSetupTests {
    static let keyID = String(repeating: "k", count: 43)

    @Test func parsesSetupArguments() throws {
        let setup = try CommanderSetup.parse([
            "--state-repo", "shilokuma-inc/askhub-state", "--mac", "mac-mini", "--claude", "/opt/claude/claude",
            "--first-key", Self.keyID, "--key-account", "mrs1669", "--claude-capacity", "3"
        ])
        #expect(setup.configuration.stateRepository.rawValue == "shilokuma-inc/askhub-state")
        #expect(setup.configuration.mac.rawValue == "mac-mini")
        #expect(setup.configuration.keyAccounts == ["mrs1669"])
        #expect(setup.configuration.capacity == .init(claude: 3, build: 0))
        #expect(setup.firstKey.rawValue == Self.keyID)
        let failures: [([String], String)] = [
            (["--mac", "mac-mini"], "--state-repo が要る"),
            (
                ["--state-repo", "o/r", "--mac", "m", "--claude", "claude", "--first-key", Self.keyID, "--key-account", "x"],
                "claude は絶対パスで書く"
            ),
            (["--token", "ghp_x"], "知らない引数 --token"),
            (["--mac"], "--mac の値が無い")
        ]
        for (arguments, message) in failures {
            #expect(throws: CommanderSetup.Failure(message: message)) { try CommanderSetup.parse(arguments) }
        }
    }

    @Test func refusesClaudeAPIKey() {
        #expect(CommanderSetup.claudeTokenProblem("sk-ant-oat01-" + String(repeating: "x", count: 40)) == nil)
        #expect(CommanderSetup.claudeTokenProblem("sk-ant-api03-xxx")?.contains("従量課金") == true)
        #expect(CommanderSetup.claudeTokenProblem("ghp_xxx") != nil)
    }

    @Test func configurationRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CommanderSetupTests-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let configuration = try CommanderSetup.parse([
            "--state-repo", "o/r", "--mac", "mac-mini", "--claude", "/opt/claude", "--first-key", Self.keyID, "--key-account", "a"
        ]).configuration
        try configuration.save(to: url)
        #expect(try CommanderConfiguration.load(from: url) == configuration)
        // 設定に秘密は書かない
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("token"))
    }

    @Test func parsesAPNsArguments() throws {
        let setup = try APNsSetup.parse(["--key-id", "ABC123DEFG", "--team-id", "XU74X3434S", "--key-file", "/tmp/AuthKey_ABC123DEFG.p8"])
        #expect(setup.configuration == APNsConfiguration(keyId: "ABC123DEFG", teamId: "XU74X3434S", topic: "jp.shilokuma.AskHub"))
        #expect(setup.keyFile == "/tmp/AuthKey_ABC123DEFG.p8")
        let topic = try APNsSetup.parse([
            "--key-id", "ABC123DEFG", "--team-id", "XU74X3434S", "--key-file", "k.p8", "--topic", "jp.example.App"
        ])
        #expect(topic.configuration.topic == "jp.example.App")
        let failures: [([String], String)] = [
            (["--key-id", "ABC123DEFG", "--team-id", "XU74X3434S"], "--key-file が要る"),
            (["--key-id", "abc", "--team-id", "XU74X3434S", "--key-file", "k.p8"], "APNs の鍵の id は英大文字・数字の 10 文字"),
            (["--key-id", "ABC123DEFG", "--team-id", "XU74X3434S", "--key-file", "k.p8", "--topic", "app"], "topic は Bundle ID の形"),
            (["--key", "-----BEGIN PRIVATE KEY-----"], "知らない引数 --key")
        ]
        for (arguments, message) in failures {
            #expect(throws: CommanderSetup.Failure(message: message)) { try APNsSetup.parse(arguments) }
        }
    }

    @Test func readsConfigurationWithoutAPNs() throws {
        // APNs を足す前に setup で書いた設定も読める（APNs の設定が無ければ知らせない）
        let text = #"""
            {"capacity":{"build":0,"claude":2},"claude":"/opt/claude","keyAccounts":["a"],"mac":"mac-mini","stateRepository":"o/r"}
            """#
        let configuration = try JSONDecoder().decode(CommanderConfiguration.self, from: Data(text.utf8))
        #expect(configuration.apns == nil)
        var withAPNs = configuration
        withAPNs.apns = APNsConfiguration(keyId: "ABC123DEFG", teamId: "XU74X3434S")
        let encoded = try JSONEncoder().encode(withAPNs)
        #expect(try JSONDecoder().decode(CommanderConfiguration.self, from: encoded) == withAPNs)
        // 設定に鍵の値は書かない
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("PRIVATE KEY") == false)
        withAPNs.apns?.teamId = "team"
        #expect(withAPNs.problems == ["Team ID は英大文字・数字の 10 文字"])
    }

    @Test func credentialHelperAnswersOnlyGitHub() throws {
        let token = { "ghp_secret" }
        let github = "protocol=https\nhost=github.com\n"
        #expect(GitCredential.response(to: github, operation: "get", token: token) == "username=x-access-token\npassword=ghp_secret\n")
        #expect(GitCredential.response(to: "protocol=https\nhost=example.com\n", operation: "get", token: token).isEmpty)
        #expect(GitCredential.response(to: "protocol=http\nhost=github.com\n", operation: "get", token: token).isEmpty)
        #expect(GitCredential.response(to: github, operation: "store", token: token).isEmpty)
        #expect(GitCredential.response(to: github, operation: "get") { nil }.isEmpty)
        let helper = GitCredential.helper(executable: URL(fileURLWithPath: "/Users/a/Library/Application Support/AskHub/askhub-commander"))
        #expect(helper == "!'/Users/a/Library/Application Support/AskHub/askhub-commander' git-credential")
    }

    @Test func launchAgentRunsCommanderAtLogin() throws {
        let executable = URL(fileURLWithPath: "/opt/askhub/askhub-commander")
        let data = try LaunchAgent.plist(executable: executable, log: URL(fileURLWithPath: "/tmp/c.log"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["Label"] as? String == "jp.shilokuma.askhub.commander")
        #expect(plist["ProgramArguments"] as? [String] == ["/opt/askhub/askhub-commander", "run"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["StandardOutPath"] as? String == "/tmp/c.log")
    }

    @Test func selfCheckReportsTokensWithoutValues() {
        let empty = MachineProbe(secrets: InMemorySecretStore(), volume: FileManager.default.temporaryDirectory).selfCheck()
        #expect(empty.githubToken == .missing)
        #expect(empty.claudeToken == .missing)
        let secrets = InMemorySecretStore([.githubToken: Data("ghp_x".utf8), .claudeToken: Data("sk-ant-api03-x".utf8)])
        let check = MachineProbe(secrets: secrets, volume: FileManager.default.temporaryDirectory).selfCheck()
        #expect(check.githubToken == .ok)
        #expect(check.claudeToken == .invalid)
    }

    // MARK: - 公開鍵の一覧

    /// 最初の鍵が自分で署名した、最初の記録を置く
    private func ledger(with key: P256.Signing.PrivateKey, account: String = "mrs1669") async throws -> (InMemoryStateStore, KeyID) {
        let der = key.publicKey.derRepresentation
        let keyID = IntentSignature.keyID(publicKeyDER: der)
        let record = KeyLedger.Record(
            seq: 1,
            action: .add,
            keyId: keyID,
            publicKey: Base64URL.encode(der),
            account: account,
            label: "iPhone",
            issuedAt: Timestamp(Date(timeIntervalSince1970: 1_793_757_600)),
            signedBy: keyID
        )
        let signed = try KeyLedger.sign(record) { try key.signature(for: $0) }
        let store = InMemoryStateStore()
        await store.put(StatePath.key(seq: 1), data: CanonicalJSON.data(for: signed))
        return (store, keyID)
    }

    @Test func trustedKeysVerifyIntentsSignedByRegisteredKey() async throws {
        let key = P256.Signing.PrivateKey()
        let (store, keyID) = try await ledger(with: key)
        let anchor = TrustAnchor(store: InMemorySecretStore())
        try anchor.pin(firstKey: keyID)
        let verifier = try await TrustedKeys(anchor: anchor, store: store, accounts: ["mrs1669"]) { _ in }.verifier()
        #expect(verifier.publicKeys[keyID] == key.publicKey.derRepresentation)
    }

    @Test func trustedKeysRefuseWithoutPin() async throws {
        let (store, _) = try await ledger(with: P256.Signing.PrivateKey())
        let keys = TrustedKeys(anchor: TrustAnchor(store: InMemorySecretStore()), store: store, accounts: ["mrs1669"]) { _ in }
        await #expect(throws: CommanderError.self) { try await keys.verifier() }
    }
}
