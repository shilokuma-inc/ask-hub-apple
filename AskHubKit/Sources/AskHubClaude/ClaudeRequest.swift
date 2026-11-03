import AskHubCommands
import AskHubProtocol
import Foundation

/// 1 回の Claude の呼び出し（`docs/renewal/flows.md` の「質問づくり・説明・確かめを Claude に頼むとき」）
public struct ClaudeRequest: Equatable, Sendable {
    /// 頼むこと（`-p` に渡す）
    public var prompt: String
    /// 決まった規則（`--append-system-prompt`）。`--restricted` では CLAUDE.md が読まれないので、リポジトリの事実もここに入れる
    public var systemPrompt: String
    /// ジョブの種類ごとに必ず指定する（指定しないと、既定のモデルが認証の方式やアカウントで変わる）
    public var model: String
    /// 返してもらう形（`--json-schema`）
    public var outputSchema: JSONValue
    /// 使える道具。段階 2 のジョブは読むだけ（`Read`・`Grep`・`Glob`）
    public var tools: [String]
    /// 読んでよい場所。`--restricted` では、ファイルの道具はここと `additionalDirectories` に限られる
    public var workingDirectory: URL
    public var additionalDirectories: [URL]
    public var timeout: Duration
    /// 続ける会話（`--resume`）。結果を直させるときに使う
    public var resume: String?

    public init(
        prompt: String,
        systemPrompt: String = "",
        model: String,
        outputSchema: JSONValue,
        tools: [String] = ClaudeRequest.readOnlyTools,
        workingDirectory: URL,
        additionalDirectories: [URL] = [],
        timeout: Duration,
        resume: String? = nil
    ) {
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.model = model
        self.outputSchema = outputSchema
        self.tools = tools
        self.workingDirectory = workingDirectory
        self.additionalDirectories = additionalDirectories
        self.timeout = timeout
        self.resume = resume
    }

    /// 読むだけの道具（ファイルを読む・探す）。書く・コマンドを流す道具は渡さない
    public static let readOnlyTools = ["Read", "Grep", "Glob"]
}

/// Mac ごとの Claude の呼び出しの設定。
///
/// `oauthToken` は Keychain から読んだ setup-token。`description` には出さない
public struct ClaudeSetup: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// 版を固定した `claude` の実行ファイル（絶対パス）
    public var executable: URL
    /// ワーカー専用の設定フォルダ（`CLAUDE_CONFIG_DIR`）。人の `~/.claude` の指示・hook・プラグインを効かせない
    public var configDirectory: URL
    public var homeDirectory: URL
    public var temporaryDirectory: URL
    public var oauthToken: String
    /// 子に渡す `PATH`
    public var path: String
    /// 引数の全体の大きさの上限（macOS の引数と環境変数の上限 1 MiB より十分に小さくする）
    public var maximumArgumentBytes: Int

    public init(
        executable: URL,
        configDirectory: URL,
        homeDirectory: URL,
        temporaryDirectory: URL,
        oauthToken: String,
        path: String = "/usr/bin:/bin:/usr/sbin:/sbin",
        maximumArgumentBytes: Int = 256_000
    ) {
        self.executable = executable
        self.configDirectory = configDirectory
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.oauthToken = oauthToken
        self.path = path
        self.maximumArgumentBytes = maximumArgumentBytes
    }

    public var description: String {
        "ClaudeSetup(executable: \(executable.path), configDirectory: \(configDirectory.path), oauthToken: <伏せた>)"
    }

    public var debugDescription: String { description }
}
