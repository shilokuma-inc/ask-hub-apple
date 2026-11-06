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
        var configuration = setup.configuration
        // 後から足した APNs の設定は、setup を流し直しても残す
        configuration.apns = (try? CommanderConfiguration.load(from: paths.configuration))?.apns
        do {
            try storeToken(.githubToken, prompt: "GitHub のトークン（状態リポジトリと対象のリポジトリを読み書きできるもの）: ", in: secrets) { _ in nil }
            try storeToken(.claudeToken, prompt: "Claude の setup-token: ", in: secrets, problem: CommanderSetup.claudeTokenProblem)
            try TrustAnchor(store: secrets).pin(firstKey: setup.firstKey)
            try configuration.save(to: paths.configuration)
        } catch {
            fail("セットアップを終えられない（\(error)）", status: EX_SOFTWARE)
        }
        print("""
            設定を \(paths.configuration.path) に書き、トークンを Keychain に置きました。
            次に launch-agent で常駐の定義を書き、出てくるコマンドで登録してください
            """)
    }

    /// APNs の鍵（.p8）を Keychain に置き、鍵の id と Team ID を設定に足す。鍵の値は設定にも出力にも書かない
    static func apns(_ arguments: [String]) {
        let setup: APNsSetup
        do {
            setup = try APNsSetup.parse(arguments)
        } catch {
            fail("\(error.message)\n\(usage)", status: EX_USAGE)
        }
        guard var configuration = try? CommanderConfiguration.load(from: paths.configuration) else {
            fail("設定（\(paths.configuration.path)）を読めない。先に setup を流す", status: EX_CONFIG)
        }
        let url = URL(fileURLWithPath: (setup.keyFile as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url), APNsKey.parse(data) != nil else {
            fail("\(url.path) を APNs の鍵（.p8）として読めない", status: EX_DATAERR)
        }
        configuration.apns = setup.configuration
        do {
            try secrets.write(data, for: .apnsKey)
            try configuration.save(to: paths.configuration)
        } catch {
            fail("APNs の鍵を登録できない（\(error)）", status: EX_SOFTWARE)
        }
        print("""
            APNs の鍵（\(setup.configuration.keyId)、Team \(setup.configuration.teamId)、\(setup.configuration.topic)）を Keychain に置き、設定に足しました。
            \(url.path) はこの Mac に残さず、安全な場所（パスワードマネージャーなど）に移してください（Apple Developer からは一度しか落とせません）。
            常駐を読み込み直すと、通知を送り始めます:
              launchctl kickstart -k gui/\(getuid())/\(LaunchAgent.label)
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
        let response: String
        do {
            response = try GitCredential.response(to: request, operation: arguments.first ?? "") {
                let token = try secrets.read(.githubToken).flatMap { String(bytes: $0, encoding: .utf8) }
                // 理由は標準エラーに出す（git の失敗の文に入り、試行の記録で分かる。トークンの値は出さない）
                if token == nil {
                    FileHandle.standardError.write(Data("askhub-commander git-credential: Keychain に GitHub のトークンが無い\n".utf8))
                }
                return token
            }
        } catch {
            FileHandle.standardError.write(Data("askhub-commander git-credential: Keychain を読めない（\(error)）\n".utf8))
            response = ""
        }
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
        let apns = configuration?.apns.map { "\($0.keyId)（Team \($0.teamId)、\($0.topic)）、鍵: \(APNsKey.state(in: secrets).rawValue)" }
        print("""
            版: \(CommanderVersion.current)
            設定: \(configuration.map { "\($0.stateRepository)（\($0.mac)、claude \($0.claude)）" } ?? "読めない（setup を流す）")
            Keychain: \(selfCheck.keychain.rawValue)
            GitHub のトークン: \(selfCheck.githubToken.rawValue)、Claude のトークン: \(selfCheck.claudeToken.rawValue)
            最初の鍵: \(firstKey?.rawValue ?? "固定していない")
            APNs: \(apns ?? "設定していない（通知を送らない。apns で登録する）")
            """)
    }
}
