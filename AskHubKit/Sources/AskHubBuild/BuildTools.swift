import AskHubCommands
import Foundation

/// ビルドとテストに使う道具（`xcrun` の下の `xcodebuild`・`simctl`・`xcresulttool`）と、それに渡す環境変数。
///
/// 環境変数はワーカーのものを引き継がずに作り直し、トークンなどの秘密を含めない（`docs/renewal/security.md` の「資格情報を渡さない」）
public struct BuildTools: Sendable {
    public var xcrun: URL
    /// 使う Xcode（`DEVELOPER_DIR`）。nil なら `xcode-select` で選んだもの
    public var developerDirectory: URL?
    /// HOME（本当のホームフォルダ）。Simulator（CoreSimulator）と Xcode の置き場所がこの下にあるので、差し替えない
    public var home: URL
    /// TMPDIR（ワーカー専用のフォルダの下）
    public var temporaryDirectory: URL
    /// プロジェクトを作る道具（`xcodegen` など）を探すフォルダ。ワーカーの PATH は引き継がないので、決まった置き場所から順に探す
    public var toolDirectories: [URL]
    /// ログインの名前。プロジェクトを作る道具にだけ `USER`・`LOGNAME` で渡す（XcodeGen は人ごとの設定の名前に使い、無いと止まる）
    public var userName: String

    /// Homebrew（Apple シリコン・Intel）と、人のホームフォルダの `~/.local/bin`
    public static func defaultToolDirectories(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            home.appendingPathComponent(".local/bin", isDirectory: true)
        ]
    }

    /// `toolDirectories` が nil なら `defaultToolDirectories(home:)`
    public init(
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        developerDirectory: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL,
        toolDirectories: [URL]? = nil,
        userName: String = NSUserName()
    ) {
        self.xcrun = xcrun
        self.developerDirectory = developerDirectory
        self.home = home
        self.temporaryDirectory = temporaryDirectory
        self.toolDirectories = toolDirectories ?? Self.defaultToolDirectories(home: home)
        self.userName = userName
    }

    /// 子に渡す環境変数。ここに無いものは渡らない
    public var environment: [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": temporaryDirectory.path,
            // エラーの文を英語で受け取る（失敗の区分の判定が文に頼るため）
            "LANG": "en_US.UTF-8",
            // パッケージの解決で git が人の設定（credential helper など）を読まず、入力も待たないようにする
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0"
        ]
        if let developerDirectory {
            environment["DEVELOPER_DIR"] = developerDirectory.path
        }
        return environment
    }

    /// 使う Xcode のパス（`Xcode.app` か、その下の `Contents/Developer`）を `DEVELOPER_DIR` の形（`Contents/Developer`）にする
    public static func developerDirectory(forXcode path: String) -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        return url.pathExtension == "app" ? url.appendingPathComponent("Contents/Developer", isDirectory: true) : url
    }

    /// 決めた Xcode（`developerDirectory`）を使えない理由。決めていない・使えるなら nil。
    /// 無いフォルダを `DEVELOPER_DIR` に渡すと `xcrun` が「missing DEVELOPER_DIR path」で止まり、理由が分かりにくいので、流す前に確かめる
    public var developerDirectoryProblem: String? {
        guard let developerDirectory else { return nil }
        let xcodebuild = developerDirectory.appendingPathComponent("usr/bin/xcodebuild")
        guard !FileManager.default.isExecutableFile(atPath: xcodebuild.path) else { return nil }
        return "ワーカーが使う Xcode として設定した \(developerDirectory.path) に xcodebuild が無い（Xcode を消したか、名前を変えたか）。"
            + "この Mac で設定の Xcode を決め直す（`askhub-commander xcode <Xcode.app のパス>`。ワーカーは `askhub-worker xcode`。"
            + "xcode-select で選んだものに戻すなら `xcode --unset`）"
    }

    /// 使う Xcode の版（`xcodebuild -version` の 1 行目の `Xcode 27.1` の `27.1`）。測れなければ nil
    public func xcodeVersion(runner: any CommandRunning, timeout: Duration = .seconds(60)) async -> String? {
        guard developerDirectoryProblem == nil,
              let result = try? await runner.run(command(["xcodebuild", "-version"], in: temporaryDirectory, timeout: timeout)),
              result.succeeded else { return nil }
        return Self.xcodeVersion(fromVersionOutput: result.outputText)
    }

    /// `xcodebuild -version` の出力から版を読む
    static func xcodeVersion(fromVersionOutput output: String) -> String? {
        let words = output.split(whereSeparator: \.isNewline).first?.split(separator: " ") ?? []
        guard words.count == 2, words[0] == "Xcode" else { return nil }
        return String(words[1])
    }

    /// プロジェクトを作る道具に渡す環境変数（`environment` に、ログインの名前を足したもの）
    var generatorEnvironment: [String: String] {
        environment.merging(["USER": userName, "LOGNAME": userName]) { $1 }
    }

    /// `xcrun <arguments>` を、`directory` で、上限 `timeout` で流すコマンド
    func command(_ arguments: [String], in directory: URL, timeout: Duration) -> Command {
        Command(executable: xcrun, arguments: arguments, environment: environment, workingDirectory: directory, timeout: timeout)
    }

    /// `toolDirectories` を順に見て、最初に見つかった `name` の実行ファイル。無ければ nil
    func tool(named name: String) -> URL? {
        toolDirectories.lazy.map { $0.appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

extension CommandResult {
    /// 標準出力と標準エラーを文字列にする。末尾だけを残した出力は文字の途中で切れることがあるので、壊れた部分を置き換えて読む
    var outputText: String {
        // swiftlint:disable:next optional_data_string_conversion
        let output = String(decoding: standardOutput, as: UTF8.self)
        // swiftlint:disable:next optional_data_string_conversion
        let error = String(decoding: standardError, as: UTF8.self)
        return [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
