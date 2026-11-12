#if os(macOS)
import AskHubBuild
import AskHubCommands
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
        // 後から決めた Xcode と、管理用のトークンを置いた持ち主は、setup を流し直しても残す（xcode --unset で戻す）
        configuration.xcode = MachineConfiguration.preservedXcode(at: paths.configuration)
        configuration.adminOwners = MachineConfiguration.preservedAdminOwners(at: paths.configuration)
        adjust(&configuration)
        do {
            for owner in configuration.tokenOwners {
                try storeGitHubToken(for: owner)
            }
            try storeClaudeToken()
            try TrustAnchor(store: secrets).pin(firstKey: setup.firstKey)
            // 前の 1 つの GitHub のトークンは、持ち主ごとのトークンに置き換えたので使わない。Keychain に残さない
            if try secrets.read(.githubToken) != nil {
                try secrets.delete(.githubToken)
                print("前の 1 つの GitHub のトークンを Keychain から消しました（持ち主ごとのトークンを使う）。")
            }
            try configuration.save(to: paths.configuration)
        } catch {
            fail("セットアップを終えられない（\(error)）", status: EX_SOFTWARE)
        }
        print("設定を \(paths.configuration.path) に書き、トークンを Keychain に置きました。")
        if let xcode = configuration.xcode { print("ビルドとテストに使う Xcode は、前の設定のまま（\(xcode)）です。") }
    }

    /// `xcode <Xcode.app のパス>`: ビルドとテストに使う Xcode を決める（`xcode --unset` で xcode-select で選んだものに戻す）。
    /// 決める前に、その Xcode の `xcodebuild -version` を読めることを確かめる。常駐のループは起動したときの値を使うので、読み込み直してもらう
    public func xcode(_ arguments: [String]) async {
        let setup: XcodeSetup
        do {
            setup = try XcodeSetup.parse(arguments)
        } catch {
            fail("\(error.message)\n使い方: \(role.program) xcode <Xcode.app のパス> | --unset", status: EX_USAGE)
        }
        var configuration = loadConfiguration()
        switch setup {
        case .set(let path): configuration.xcode = path
        case .unset: configuration.xcode = nil
        }
        let tools = configuration.buildTools(paths: paths)
        if case .set(let path) = setup, tools.developerDirectoryProblem != nil {
            fail("\(path) に Xcode が無い（Xcode.app か、その下の Contents/Developer のパスを渡す）", status: EX_DATAERR)
        }
        try? FileManager.default.createDirectory(at: paths.buildTemporary, withIntermediateDirectories: true)
        let version = await tools.xcodeVersion(runner: ProcessCommandRunner())
        // 決めるときだけ、版を読めることを確かめる（戻すときは、xcode-select が Command Line Tools を指していても戻せるようにする）
        if case .set(let path) = setup, version == nil {
            fail("\(path) の xcodebuild -version を読めない（ライセンスに同意していない、など）", status: EX_DATAERR)
        }
        do {
            try configuration.save(to: paths.configuration)
        } catch {
            fail("設定を書けない（\(error.localizedDescription)）", status: EX_CANTCREAT)
        }
        let manual = role == .worker ? "（ターミナルで run を流しているなら、止めて流し直す）" : ""
        let chosen = configuration.xcode.map { "\($0) に決めました" } ?? "xcode-select で選んだものに戻しました"
        print("""
            ビルドとテストに使う Xcode を \(chosen)（\(version.map { "Xcode \($0)" } ?? "版を読めない")）。
            動いているループは起動したときの値を使うので、読み込み直してください\(manual):
              launchctl kickstart -k gui/\(getuid())/\(role.launchAgentLabel)
            """)
    }

    /// `token <持ち主>`: 持ち主の GitHub のトークンを入れ直す・足す。足した持ち主は設定にも書く（常駐の自己診断が、印を書くたびに読み直す）
    public func token(_ arguments: [String]) {
        guard arguments.count == 1, let owner = GitHubTokens.normalizedOwner(arguments[0]) else {
            fail("使い方: \(role.program) token <GitHub の持ち主（organization・個人）>", status: EX_USAGE)
        }
        var configuration = loadConfiguration()
        do {
            try storeGitHubToken(for: owner)
            if configuration.addTokenOwner(owner) { try configuration.save(to: paths.configuration) }
        } catch {
            fail("トークンを置けない（\(error)）", status: EX_SOFTWARE)
        }
        print("""
            \(owner) の GitHub のトークンを Keychain に置きました。トークンを置いた持ち主: \(configuration.tokenOwners.joined(separator: "、"))
            常駐していれば、読み込み直さなくても次の要求から使い、次の生きている印（10 分ごと）の自己診断にも出します
            """)
    }

    /// `admin-token <持ち主>`: 持ち主の管理用のトークンを入れ直す・足す（司令塔だけ）。足した持ち主は設定の `adminOwners` にも書く
    /// （常駐の自己診断が、印を書くたびに読み直す）。管理用のトークンは、署名した人の意図の処理（保護の設定・対象に加えるときの準備）にだけ使い、
    /// git・Claude のジョブ・ワーカーには渡さない（`docs/renewal/security.md` の「管理用のトークン」）
    public func adminToken(_ arguments: [String]) {
        guard role == .commander else { fail("管理用のトークンは、常時オンの Mac の askhub-commander にだけ置く", status: EX_USAGE) }
        guard arguments.count == 1, let owner = GitHubTokens.normalizedOwner(arguments[0]) else {
            fail("使い方: \(role.program) admin-token <GitHub の持ち主（organization・個人）>", status: EX_USAGE)
        }
        var configuration = loadConfiguration()
        do {
            try storeAdminToken(for: owner)
            if configuration.addAdminOwner(owner) { try configuration.save(to: paths.configuration) }
        } catch {
            fail("トークンを置けない（\(error)）", status: EX_SOFTWARE)
        }
        print("""
            \(owner) の管理用のトークンを Keychain に置きました。管理用のトークンを置いた持ち主: \(configuration.adminTokenOwners.joined(separator: "、"))
            常駐していれば、読み込み直さなくても次の管理の操作から使い、次の生きている印（10 分ごと）の自己診断にも期限を出します
            """)
    }

    /// `claude-token`: Claude の setup-token を入れ直す（期限の 1 年が近づいたら、`claude setup-token` で作り直して貼る）。
    /// 常駐のループは起動したときに読んだ値を使うので、読み込み直してもらう
    public func replaceClaudeToken(_ arguments: [String]) {
        guard arguments.isEmpty else { fail("使い方: \(role.program) claude-token", status: EX_USAGE) }
        _ = loadConfiguration()
        do {
            try storeClaudeToken()
        } catch {
            fail("トークンを置けない（\(error)）", status: EX_SOFTWARE)
        }
        let manual = role == .worker ? "（ターミナルで run を流しているなら、止めて流し直す）" : ""
        print("""
            Claude の setup-token を Keychain に置きました。
            動いているループは起動したときの値を使うので、読み込み直してください\(manual):
              launchctl kickstart -k gui/\(getuid())/\(role.launchAgentLabel)
            """)
    }

    /// Claude の setup-token を、端末で伏せて入れてもらって置く。新しい値を入れたら、入れた日を記録する（期限の目安。値は記録しない）
    func storeClaudeToken() throws {
        guard try storeSecret(.claudeToken, prompt: "Claude の setup-token: ", problem: MachineSetup.claudeTokenProblem) else { return }
        try ClaudeTokenRecord(storedAt: Timestamp(Date())).save(to: paths.claudeTokenRecord)
    }

    /// 持ち主の fine-grained token を、端末で伏せて入れてもらって置く。すでにあれば、空のまま Enter で今のままにする
    func storeGitHubToken(for owner: String) throws {
        let tokens = GitHubTokens(secrets: secrets)
        let existing = try tokens.contains(owner)
        let prompt = "\(owner) の GitHub の fine-grained token（github_pat_ で始まる）: "
        let value = readSecret(existing ? prompt + "（今のままなら空で Enter）" : prompt)
        if value.isEmpty {
            guard existing else { fail("値が空", status: EX_USAGE) }
            return
        }
        if let problem = GitHubTokens.problem(of: value) { fail(problem, status: EX_USAGE) }
        // 毎日のトークン（Claude の書いたコードを push する）に、管理用の権限を持たせない
        if try GitHubAdminTokens(secrets: secrets).token(for: owner) == value {
            fail("\(owner) の管理用のトークンと同じ値。毎日のトークンは別に作る（Administration・Workflows を付けない）", status: EX_USAGE)
        }
        try tokens.store(value, for: owner)
    }

    /// 持ち主の管理用の fine-grained token を、端末で伏せて入れてもらって置く。すでにあれば、空のまま Enter で今のままにする。
    /// 毎日のトークンと同じ値は断る（管理用の権限を毎日の push に使わない）
    func storeAdminToken(for owner: String) throws {
        let tokens = GitHubAdminTokens(secrets: secrets)
        let existing = try tokens.contains(owner)
        let prompt = "\(owner) の管理用の fine-grained token（github_pat_ で始まる。毎日のトークンとは別に作る）: "
        let value = readSecret(existing ? prompt + "（今のままなら空で Enter）" : prompt)
        if value.isEmpty {
            guard existing else { fail("値が空", status: EX_USAGE) }
            return
        }
        if let problem = GitHubTokens.problem(of: value) { fail(problem, status: EX_USAGE) }
        if try GitHubTokens(secrets: secrets).token(for: owner) == value {
            fail("\(owner) の毎日のトークンと同じ値。管理用のトークンは別に作る（docs/renewal/operations.md の「管理用のトークン」）", status: EX_USAGE)
        }
        try tokens.store(value, for: owner)
    }

    /// 端末で伏せて入れてもらい、Keychain に置く。すでにあれば、空のまま Enter で今のままにする。新しい値を置いたら true
    @discardableResult
    func storeSecret(_ item: SecretItem, prompt: String, problem: (String) -> String?) throws -> Bool {
        let existing = try secrets.read(item) != nil
        let value = readSecret(existing ? prompt + "（今のままなら空で Enter）" : prompt)
        if value.isEmpty {
            guard existing else { fail("値が空", status: EX_USAGE) }
            return false
        }
        if let problem = problem(value) { fail(problem, status: EX_USAGE) }
        try secrets.write(Data(value.utf8), for: item)
        return true
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

    /// git の credential helper。github.com の https のときだけ、問い合わせの path の持ち主のトークンを Keychain から返す
    public func gitCredential(_ arguments: [String]) {
        let request = String(bytes: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let response: String
        do {
            response = try GitCredential.response(to: request, operation: arguments.first ?? "", tokens: GitHubTokens(secrets: secrets))
        } catch {
            // 理由は標準エラーに出す（git の失敗の文に入り、試行の記録で分かる。トークンの値は出さない）。何も返さず、git を失敗させる
            FileHandle.standardError.write(Data("\(role.program) git-credential: \(error)\n".utf8))
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

    /// 設定と Keychain の様子（秘密の値は出さない）。トークンの期限は GitHub に問い合わせる。役割ごとの行は呼ぶ側で足す
    public func checkLines(version: String) async -> [String] {
        let configuration = try? MachineConfiguration.load(from: paths.configuration, role: role)
        let owners = configuration?.tokenOwners ?? []
        let adminOwners = configuration?.adminTokenOwners ?? []
        let probe = MachineProbe(
            secrets: secrets,
            volume: paths.root,
            owners: { owners },
            githubExpiry: GitHubTokenExpiry(),
            adminOwners: { adminOwners },
            adminExpiry: GitHubTokenExpiry(),
            claudeTokenRecord: paths.claudeTokenRecord
        )
        let selfCheck = await probe.selfCheck()
        let describe = { (token: SelfCheck.GitHubToken) in
            "\(token.owner) \(token.state.rawValue)、\(token.expiresAt.map { "期限 \($0)" } ?? "期限なし・分からない")"
        }
        let ownerStates = (selfCheck.githubTokens ?? []).map(describe)
        let adminStates = (selfCheck.githubAdminTokens ?? []).map(describe)
        let claudeExpiry = selfCheck.claudeTokenExpiresAt.map { "期限 \($0)（入れた日から 1 年）" } ?? "期限が分からない（claude-token で入れ直すと記録する）"
        let firstKey = (try? TrustAnchor(store: secrets).firstKey()).flatMap { $0 }
        var xcode = "設定を読めない"
        if let configuration { xcode = await xcodeLine(configuration) }
        let summary = configuration.map { configuration in
            let capacity = "Claude \(configuration.capacity.claude)・ビルド \(configuration.capacity.build)"
            let mac = "\(configuration.mac)、\(configuration.kind.rawValue)"
            return "\(configuration.stateRepository)（\(mac)、同時 \(capacity)、claude \(configuration.claude)）"
        }
        let admin = adminStates.isEmpty ? "置いていない（管理の操作は断る。admin-token <持ち主> で入れる）" : adminStates.joined(separator: "・")
        return [
            "版: \(version)",
            "設定: \(summary ?? "読めない（setup を流す）")",
            "Keychain: \(selfCheck.keychain.rawValue)",
            "GitHub のトークン: \(selfCheck.githubToken.rawValue)（\(ownerStates.joined(separator: "・"))）"
        ] + (role == .commander ? ["管理用のトークン: \(admin)"] : []) + [
            "Claude のトークン: \(selfCheck.claudeToken.rawValue)（\(claudeExpiry)）",
            "GitHub の REST の残り: \(selfCheck.githubRateLimit.map { "\($0.remaining) / \($0.limit) 回（\($0.resetAt) に戻る）" } ?? "読めない")",
            "最初の鍵: \(firstKey?.rawValue ?? "固定していない")",
            "Xcode: \(xcode)"
        ]
    }

    /// ビルドとテストに使う Xcode と、その版。決めていなければ、xcode-select で選んだものを出す
    func xcodeLine(_ configuration: MachineConfiguration) async -> String {
        let tools = configuration.buildTools(paths: paths)
        if let xcode = configuration.xcode, tools.developerDirectoryProblem != nil {
            return "設定の \(xcode) に Xcode が無い（ビルドとテストは止まる。xcode <Xcode.app のパス> で決め直す）"
        }
        try? FileManager.default.createDirectory(at: paths.buildTemporary, withIntermediateDirectories: true)
        let version = await tools.xcodeVersion(runner: ProcessCommandRunner()).map { "Xcode \($0)" } ?? "版を読めない"
        if let xcode = configuration.xcode { return "\(xcode)（\(version)）" }
        let select = Command(
            executable: URL(fileURLWithPath: "/usr/bin/xcode-select"),
            arguments: ["-p"],
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: paths.buildTemporary,
            timeout: .seconds(30)
        )
        let selected = (try? await ProcessCommandRunner().run(select)).flatMap { result in
            result.succeeded ? String(bytes: result.standardOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        return "設定で決めていない。xcode-select で選んだ \(selected ?? "もの")（\(version)）。人が切り替えると変わるので、xcode <Xcode.app のパス> で決める"
    }
}
#endif
