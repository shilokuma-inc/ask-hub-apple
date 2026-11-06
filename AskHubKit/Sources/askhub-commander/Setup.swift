import AskHubCommander
import AskHubKeychain
import AskHubProtocol
import Foundation

extension AskHubCommanderMain {
    /// 設定を書き、トークンを Keychain に置き、最初の鍵を固定する
    static func setup(_ arguments: [String]) {
        let setup: CommanderSetup
        do {
            setup = try CommanderSetup.parse(arguments)
        } catch {
            fail("\(error.message)\n\(usage)", status: EX_USAGE)
        }
        let secrets = secrets
        do {
            try storeToken(.githubToken, prompt: "GitHub のトークン（状態リポジトリと対象のリポジトリを読み書きできるもの）: ", in: secrets) { _ in nil }
            try storeToken(.claudeToken, prompt: "Claude の setup-token: ", in: secrets, problem: CommanderSetup.claudeTokenProblem)
            try TrustAnchor(store: secrets).pin(firstKey: setup.firstKey)
            try setup.configuration.save(to: paths.configuration)
        } catch {
            fail("セットアップを終えられない（\(error)）", status: EX_SOFTWARE)
        }
        print("""
            設定を \(paths.configuration.path) に書き、トークンを Keychain に置きました。
            次に launch-agent で常駐の定義を書き、出てくるコマンドで登録してください
            """)
    }

    /// 端末で伏せて入れてもらい、Keychain に置く。すでにあれば、空のまま Enter で今のままにする
    private static func storeToken(
        _ item: SecretItem,
        prompt: String,
        in secrets: KeychainSecretStore,
        problem: (String) -> String?
    ) throws {
        let existing = try secrets.read(item) != nil
        let token = readSecret(existing ? prompt + "（今のままなら空で Enter）" : prompt)
        if token.isEmpty {
            guard existing else { fail("値が空", status: EX_USAGE) }
            return
        }
        if let problem = problem(token) { fail(problem, status: EX_USAGE) }
        try secrets.write(Data(token.utf8), for: item)
    }

    /// 端末から、表示せずに 1 行読む（端末でなければ止める）
    private static func readSecret(_ prompt: String) -> String {
        var buffer = [CChar](repeating: 0, count: 4_096)
        defer { buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        guard let line = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            fail("端末から入れてください（トークンは引数や標準入力では受け取りません）", status: EX_USAGE)
        }
        return String(cString: line).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// git の credential helper。github.com の https のときだけ、Keychain の GitHub のトークンを返す
    static func gitCredential(_ arguments: [String]) {
        let request = String(bytes: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let response = (try? GitCredential.response(to: request, operation: arguments.first ?? "") {
            try secrets.read(.githubToken).flatMap { String(bytes: $0, encoding: .utf8) }
        }) ?? ""
        FileHandle.standardOutput.write(Data(response.utf8))
    }

    /// LaunchAgent の定義を書き、登録のコマンドを出す（登録は人が流す）
    static func launchAgent() {
        let path = LaunchAgent.path()
        do {
            try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try LaunchAgent.plist(executable: executable, log: paths.log).write(to: path, options: .atomic)
        } catch {
            fail("LaunchAgent の定義を書けない（\(error.localizedDescription)）", status: EX_CANTCREAT)
        }
        print("""
            \(path.path) を書きました。次のコマンドで登録します（ログ: \(paths.log.path)）:
              launchctl bootstrap gui/\(getuid()) '\(path.path)'
            書き直した後に読み込み直すときは:
              launchctl bootout gui/\(getuid())/\(LaunchAgent.label) && launchctl bootstrap gui/\(getuid()) '\(path.path)'
            """)
    }

    /// 設定と Keychain の様子を出す（秘密の値は出さない）
    static func check() {
        let configuration = try? CommanderConfiguration.load(from: paths.configuration)
        let selfCheck = MachineProbe(secrets: secrets, volume: paths.root).selfCheck()
        let firstKey = (try? TrustAnchor(store: secrets).firstKey()).flatMap { $0 }
        print("""
            版: \(CommanderVersion.current)
            設定: \(configuration.map { "\($0.stateRepository)（\($0.mac)、claude \($0.claude)）" } ?? "読めない（setup を流す）")
            Keychain: \(selfCheck.keychain.rawValue)
            GitHub のトークン: \(selfCheck.githubToken.rawValue)、Claude のトークン: \(selfCheck.claudeToken.rawValue)
            最初の鍵: \(firstKey?.rawValue ?? "固定していない")
            """)
    }
}
