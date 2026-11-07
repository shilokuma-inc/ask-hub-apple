@testable import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 司令塔とワーカーの実行ファイルの部品（設定・セットアップの引数・credential helper・LaunchAgent・公開鍵の一覧・自己診断）
struct MachineSetupTests {
    static let keyID = String(repeating: "k", count: 43)

    @Test func parsesSetupArguments() throws {
        let setup = try MachineSetup.parse([
            "--state-repo", "shilokuma-inc/askhub-state", "--mac", "mac-mini", "--claude", "/opt/claude/claude",
            "--first-key", Self.keyID, "--key-account", "mrs1669", "--claude-capacity", "3"
        ], role: .commander)
        #expect(setup.configuration.stateRepository.rawValue == "shilokuma-inc/askhub-state")
        #expect(setup.configuration.mac.rawValue == "mac-mini")
        #expect(setup.configuration.keyAccounts == ["mrs1669"])
        #expect(setup.configuration.capacity == .init(claude: 3, build: 0))
        #expect(setup.configuration.kind == .alwaysOn)
        #expect(setup.firstKey.rawValue == Self.keyID)
        let failures: [([String], String)] = [
            (["--mac", "mac-mini"], "--state-repo が要る"),
            (
                ["--state-repo", "o/r", "--mac", "m", "--claude", "claude", "--first-key", Self.keyID, "--key-account", "x"],
                "claude は絶対パスで書く"
            ),
            (["--token", "ghp_x"], "知らない引数 --token"),
            (["--mac"], "--mac の値が無い"),
            // 司令塔は常時オンの Mac だけ
            (["--kind", "manual"], "知らない引数 --kind")
        ]
        for (arguments, message) in failures {
            #expect(throws: MachineSetup.Failure(message: message)) { try MachineSetup.parse(arguments, role: .commander) }
        }
    }

    @Test func parsesWorkerArguments() throws {
        let base = [
            "--state-repo", "shilokuma-inc/askhub-state", "--mac", "macbook-a", "--claude", "/opt/claude/claude",
            "--first-key", Self.keyID, "--key-account", "mrs1669"
        ]
        let manual = try MachineSetup.parse(base + ["--kind", "manual"], role: .worker)
        #expect(manual.configuration.kind == .manual)
        #expect(manual.configuration.capacity == .init(claude: 2, build: 1))
        let resident = try MachineSetup.parse(
            base + ["--kind", "resident", "--claude-capacity", "1", "--build-capacity", "2"], role: .worker
        )
        #expect(resident.configuration.kind == .resident)
        #expect(resident.configuration.capacity == .init(claude: 1, build: 2))
        let kindMessage = "--kind は resident（常駐できる）か manual（常駐できない）"
        let failures: [([String], String)] = [
            (base, "--kind が要る"),
            (base + ["--kind", "alwaysOn"], kindMessage),
            (base + ["--kind", "laptop"], kindMessage),
            (base + ["--kind", "manual", "--build-capacity", "-1"], "--build-capacity は 0 以上の数")
        ]
        for (arguments, message) in failures {
            #expect(throws: MachineSetup.Failure(message: message)) { try MachineSetup.parse(arguments, role: .worker) }
        }
    }

    @Test func rolesKeepTheirOwnPlaces() {
        let home = URL(fileURLWithPath: "/Users/a")
        let worker = MachinePaths(role: .worker, home: home)
        #expect(worker.configuration.path == "/Users/a/Library/Application Support/AskHub/worker/config.json")
        #expect(worker.log.path == "/Users/a/Library/Logs/AskHub/worker.log")
        #expect(MachinePaths(role: .commander, home: home).work.path == "/Users/a/Library/Application Support/AskHub/commander/work")
        #expect(MachineRole.worker.keychainService == "jp.shilokuma.AskHub.worker")
        #expect(MachineRole.commander.keychainService == "jp.shilokuma.AskHub.commander")
        #expect(LaunchAgent.path(role: .worker, home: home).path == "/Users/a/Library/LaunchAgents/jp.shilokuma.askhub.worker.plist")
    }

    @Test func refusesClaudeAPIKey() {
        #expect(MachineSetup.claudeTokenProblem("sk-ant-oat01-" + String(repeating: "x", count: 40)) == nil)
        #expect(MachineSetup.claudeTokenProblem("sk-ant-api03-xxx")?.contains("従量課金") == true)
        #expect(MachineSetup.claudeTokenProblem("ghp_xxx") != nil)
    }

    @Test func configurationRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MachineSetupTests-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let configuration = try MachineSetup.parse([
            "--state-repo", "o/r", "--mac", "mac-mini", "--claude", "/opt/claude", "--first-key", Self.keyID, "--key-account", "a"
        ], role: .commander).configuration
        try configuration.save(to: url)
        #expect(try MachineConfiguration.load(from: url, role: .commander) == configuration)
        // 司令塔の設定をワーカーでは読まない（Keychain や置き場所を取り違えない）
        #expect(throws: (any Error).self) { try MachineConfiguration.load(from: url, role: .worker) }
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
            #expect(throws: MachineSetup.Failure(message: message)) { try APNsSetup.parse(arguments) }
        }
    }

    @Test func keepsAPNsAcrossSetup() throws {
        // APNs を足す前に setup で書いた設定も読める（APNs の設定が無ければ知らせない）
        let text = #"""
            {"capacity":{"build":0,"claude":2},"claude":"/opt/claude","keyAccounts":["a"],"kind":"alwaysOn",
             "mac":"mac-mini","stateRepository":"o/r"}
            """#
        let configuration = try JSONDecoder().decode(MachineConfiguration.self, from: Data(text.utf8))
        #expect(configuration.apns == nil)
        var withAPNs = configuration
        withAPNs.apns = APNsConfiguration(keyId: "ABC123DEFG", teamId: "XU74X3434S")
        let encoded = try JSONEncoder().encode(withAPNs)
        #expect(try JSONDecoder().decode(MachineConfiguration.self, from: encoded) == withAPNs)
        // 設定に鍵の値は書かない
        #expect(String(bytes: encoded, encoding: .utf8)?.contains("PRIVATE KEY") == false)
        // 前の形の設定（欄が足りない）からも、APNs の設定だけは読んで setup で残す（.p8 は Mac に残さないので登録し直せない）
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MachineSetupTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let previous = #"{"apns":{"keyId":"ABC123DEFG","teamId":"XU74X3434S","topic":"jp.shilokuma.AskHub"},"mac":"m"}"#
        try Data(previous.utf8).write(to: url)
        #expect(APNsSetup.preserved(at: url) == withAPNs.apns)
        #expect(APNsSetup.preserved(at: url.appendingPathExtension("missing")) == nil)
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
        let data = try LaunchAgent.plist(role: .commander, executable: executable, log: URL(fileURLWithPath: "/tmp/c.log"))
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
