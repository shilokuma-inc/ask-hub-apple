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

    public init(
        xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
        developerDirectory: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL
    ) {
        self.xcrun = xcrun
        self.developerDirectory = developerDirectory
        self.home = home
        self.temporaryDirectory = temporaryDirectory
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

    /// `xcrun <arguments>` を、`directory` で、上限 `timeout` で流すコマンド
    func command(_ arguments: [String], in directory: URL, timeout: Duration) -> Command {
        Command(executable: xcrun, arguments: arguments, environment: environment, workingDirectory: directory, timeout: timeout)
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
