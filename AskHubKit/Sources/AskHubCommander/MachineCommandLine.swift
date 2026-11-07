#if os(macOS)
import AskHubKeychain
import AskHubProtocol
import Foundation

/// 司令塔とワーカーの実行ファイルで共通の、人が端末で流すコマンド（setup・git-credential・launch-agent・check）とログ。
///
/// トークンは引数や標準入力では受け取らず、端末で伏せて入れてもらい、Keychain だけに置く（`docs/renewal/security.md` の「秘密の置き場所」）
public struct MachineCommandLine: Sendable {
    public let role: MachineRole
    public let paths: MachinePaths
    /// この実行ファイルの場所（シンボリックリンクを辿った先）。credential helper と LaunchAgent に書く
    public let executable: URL

    public init(role: MachineRole, executable: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.role = role
        self.executable = executable
        paths = MachinePaths(role: role, home: home)
    }

    /// 起動した実行ファイルの場所
    public static var currentExecutable: URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    }

    public var secrets: KeychainSecretStore { KeychainSecretStore(service: role.keychainService) }

    /// launchd の下では標準出力がファイルになり print はバッファに残るため、書いてすぐ出す
    @Sendable
    public static func log(_ message: String) {
        let time = Date().formatted(.iso8601)
        FileHandle.standardOutput.write(Data("[\(time)] \(message)\n".utf8))
    }

    public func fail(_ message: String, status: Int32) -> Never {
        FileHandle.standardError.write(Data("\(role.program): \(message)\n".utf8))
        if status != EX_OK { Self.log("終了します（終了コード \(status)）: \(message)") }
        exit(status)
    }

    // MARK: - setup

    /// 設定を書き、トークンを Keychain に置き、最初の鍵を固定する。`adjust` で役割ごとの欄（司令塔の APNs など）を足す
    public func setup(_ arguments: [String], usage: String, adjust: (inout MachineConfiguration) -> Void = { _ in }) {
        let setup: MachineSetup
        do {
            setup = try MachineSetup.parse(arguments, role: role)
        } catch {
            fail("\(error.message)\n\(usage)", status: EX_USAGE)
        }
        var configuration = setup.configuration
        adjust(&configuration)
        do {
            try storeSecret(.githubToken, prompt: "GitHub のトークン（状態リポジトリと対象のリポジトリを読み書きできるもの）: ") { _ in nil }
            try storeSecret(.claudeToken, prompt: "Claude の setup-token: ", problem: MachineSetup.claudeTokenProblem)
            try TrustAnchor(store: secrets).pin(firstKey: setup.firstKey)
            try configuration.save(to: paths.configuration)
        } catch {
            fail("セットアップを終えられない（\(error)）", status: EX_SOFTWARE)
        }
        print("設定を \(paths.configuration.path) に書き、トークンを Keychain に置きました。")
    }

    /// 端末で伏せて入れてもらい、Keychain に置く。すでにあれば、空のまま Enter で今のままにする
    func storeSecret(_ item: SecretItem, prompt: String, problem: (String) -> String?) throws {
        let existing = try secrets.read(item) != nil
        let value = readSecret(existing ? prompt + "（今のままなら空で Enter）" : prompt)
        if value.isEmpty {
            guard existing else { fail("値が空", status: EX_USAGE) }
            return
        }
        if let problem = problem(value) { fail(problem, status: EX_USAGE) }
        try secrets.write(Data(value.utf8), for: item)
    }

    /// 端末から、表示せずに 1 行読む（端末でなければ止める）
    public func readSecret(_ prompt: String) -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        defer { buffer.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard let line = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            fail("端末から入れてください（トークンは引数や標準入力では受け取りません）", status: EX_USAGE)
        }
        return String(cString: line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - run の前

    /// 設定を読む。読めなければ止める
    public func loadConfiguration() -> MachineConfiguration {
        do {
            return try MachineConfiguration.load(from: paths.configuration, role: role)
        } catch {
            fail("設定（\(paths.configuration.path)）を読めない。setup を流す（\(error.localizedDescription)）", status: EX_CONFIG)
        }
    }

    /// Keychain の Claude の setup-token。無い・形が違えば止める
    public func claudeToken() -> String {
        guard let token = try? secrets.read(.claudeToken).flatMap({ String(bytes: $0, encoding: .utf8) }),
              token.hasPrefix(MachineProbe.claudeTokenPrefix) else {
            fail("Keychain に Claude の setup-token が無い・形が違う。setup を流す", status: EX_CONFIG)
        }
        return token
    }

    // MARK: - git-credential・launch-agent・check

    /// git の credential helper。github.com の https のときだけ、Keychain の GitHub のトークンを返す
    public func gitCredential(_ arguments: [String]) {
        let request = String(bytes: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let response: String
        do {
            response = try GitCredential.response(to: request, operation: arguments.first ?? "") {
                let token = try secrets.read(.githubToken).flatMap { String(bytes: $0, encoding: .utf8) }
                // 理由は標準エラーに出す（git の失敗の文に入り、試行の記録で分かる。トークンの値は出さない）
                if token == nil {
                    FileHandle.standardError.write(Data("\(role.program) git-credential: Keychain に GitHub のトークンが無い\n".utf8))
                }
                return token
            }
        } catch {
            FileHandle.standardError.write(Data("\(role.program) git-credential: Keychain を読めない（\(error)）\n".utf8))
            response = ""
        }
        FileHandle.standardOutput.write(Data(response.utf8))
    }

    /// LaunchAgent の定義を書き、登録のコマンドを出す（登録は人が流す）
    public func launchAgent() {
        let path = LaunchAgent.path(role: role)
        do {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LaunchAgent.plist(role: role, executable: executable, log: paths.log).write(to: path, options: .atomic)
        } catch {
            fail("LaunchAgent の定義を書けない（\(error.localizedDescription)）", status: EX_CANTCREAT)
        }
        print("""
            \(path.path) を書きました。次のコマンドで登録します（ログ: \(paths.log.path)）:
              launchctl bootstrap gui/\(getuid()) '\(path.path)'
            書き直した後に読み込み直すときは:
              launchctl bootout gui/\(getuid())/\(role.launchAgentLabel) && launchctl bootstrap gui/\(getuid()) '\(path.path)'
            """)
    }

    /// 設定と Keychain の様子（秘密の値は出さない）。役割ごとの行は呼ぶ側で足す
    public func checkLines(version: String) -> [String] {
        let configuration = try? MachineConfiguration.load(from: paths.configuration, role: role)
        let selfCheck = MachineProbe(secrets: secrets, volume: paths.root).selfCheck()
        let firstKey = (try? TrustAnchor(store: secrets).firstKey()).flatMap { $0 }
        let summary = configuration.map { configuration in
            let capacity = "Claude \(configuration.capacity.claude)・ビルド \(configuration.capacity.build)"
            let mac = "\(configuration.mac)、\(configuration.kind.rawValue)"
            return "\(configuration.stateRepository)（\(mac)、同時 \(capacity)、claude \(configuration.claude)）"
        }
        return [
            "版: \(version)",
            "設定: \(summary ?? "読めない（setup を流す）")",
            "Keychain: \(selfCheck.keychain.rawValue)",
            "GitHub のトークン: \(selfCheck.githubToken.rawValue)、Claude のトークン: \(selfCheck.claudeToken.rawValue)",
            "最初の鍵: \(firstKey?.rawValue ?? "固定していない")"
        ]
    }
}
#endif
