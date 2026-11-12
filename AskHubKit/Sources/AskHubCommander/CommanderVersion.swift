import AskHubProtocol
import Foundation

/// 司令塔・ワーカー・非常口の版（同じパッケージから作るので同じ。`docs/renewal/operations.md` の「版」）。
///
/// 版とコミットは、ビルドのときに実行ファイルに埋め込んだ Info.plist（`__TEXT,__info_plist`。`scripts/machine/build.sh`）から読む。
/// 埋め込んでいないビルド（`swift build` をそのまま流したもの・テスト）は `0.0.0-dev`。
/// 司令塔とワーカーの照らし合わせには、版ではなく互換の番号（`MachineCompatibility.current`）を使う
public enum CommanderVersion {
    /// 埋め込んだ Info.plist から読んだ版とコミット
    public struct Build: Equatable, Sendable {
        public var version: String
        /// ビルドしたコミット。埋め込んでいなければ nil
        public var commit: String?

        /// 識別子が AskHub の実行ファイルのものでなければ、埋め込んでいないとみなす（テストを流す xctest など、ほかのプログラムの Info.plist を読まない）
        public init(infoDictionary: [String: Any]?) {
            guard let info = infoDictionary,
                  let identifier = info["CFBundleIdentifier"] as? String, identifier.hasPrefix(CommanderVersion.identifierPrefix),
                  let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else {
                self.version = CommanderVersion.development
                commit = nil
                return
            }
            self.version = version
            commit = (info[CommanderVersion.commitKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// `check` と起動のログに出す。例: 0.2.0-3-gabc1234、コミット abc1234…、互換の番号 1
        public var summary: String {
            "\(version)、コミット \(commit ?? "埋め込んでいない")、互換の番号 \(MachineCompatibility.current)"
        }
    }

    /// 埋め込んでいないビルドの版
    public static let development = "0.0.0-dev"
    /// 識別子の頭（`jp.shilokuma.askhub.commander`・`.worker`・`.cli`）
    static let identifierPrefix = "jp.shilokuma.askhub."
    /// Info.plist の、コミットの欄
    static let commitKey = "AskHubCommit"

    /// 動いている実行ファイルの版とコミット
    public static let build = Build(infoDictionary: Bundle.main.infoDictionary)

    /// 生きている印の `versions.worker`・`versions.commander` に書く版
    public static var current: String { build.version }
}
