import AskHubKit
import Foundation

/// オーケストレーターの設定。PC ごとに `~/.config/askhub/orchestrator.json` に置く（commit しない）。
///
/// Discussion #1 の Q10 により、担当リポジトリは PC ごとに重ならないよう人間が列挙する。
public struct OrchestratorConfig: Sendable, Equatable {
    /// ポーリング間隔の既定値（秒）
    public static let defaultPollInterval: Duration = .seconds(60)
    /// ポーリング間隔の下限（秒）。Search API は認証済みでも 30 回/分のため、これより短くしない
    public static let minimumPollInterval: Duration = .seconds(30)

    /// 指示として扱ってよい GitHub アカウントの login
    public let trustedAuthorLogins: [String]
    /// `needs-answer` などを検索する GitHub の organization
    public let org: String
    /// この PC が担当するリポジトリ
    public let repositories: [RepositoryConfig]
    public let pollInterval: Duration
    public let loopCommand: LoopCommandTemplate
    /// 依頼から Discussion を作らせるコマンド
    public let ideaCommand: IdeaCommandTemplate

    public var trustedAuthors: TrustedAuthors {
        TrustedAuthors(trustedAuthorLogins)
    }

    public init(
        trustedAuthorLogins: [String],
        org: String,
        repositories: [RepositoryConfig],
        pollInterval: Duration,
        loopCommand: LoopCommandTemplate,
        ideaCommand: IdeaCommandTemplate = .standard
    ) {
        self.trustedAuthorLogins = trustedAuthorLogins
        self.org = org
        self.repositories = repositories
        self.pollInterval = pollInterval
        self.loopCommand = loopCommand
        self.ideaCommand = ideaCommand
    }

    /// 担当リポジトリを `owner/repo` で探す。GitHub の名前は大文字・小文字を区別しない
    public func repository(named fullName: String) -> RepositoryConfig? {
        repositories.first { $0.fullName.caseInsensitiveCompare(fullName) == .orderedSame }
    }
}

/// 担当リポジトリ 1 つ分の設定
public struct RepositoryConfig: Sendable, Equatable {
    public let owner: String
    public let name: String
    /// メインの checkout の絶対パス
    public let checkoutPath: String

    public init(owner: String, name: String, checkoutPath: String) {
        self.owner = owner
        self.name = name
        self.checkoutPath = checkoutPath
    }

    /// `owner/repo`
    public var fullName: String {
        "\(owner)/\(name)"
    }

    /// ループの制御用 worktree のパス。
    /// `scripts/ralph-setup.sh` と同じく、checkout の隣に `<ディレクトリ名から -ios を除いたもの>-ralph-ctl` を置く
    public var controlWorktreePath: String {
        let checkout = URL(fileURLWithPath: checkoutPath, isDirectory: true)
        var directoryName = checkout.lastPathComponent
        if directoryName.hasSuffix("-ios") {
            directoryName.removeLast("-ios".count)
        }
        return checkout.deletingLastPathComponent()
            .appendingPathComponent("\(directoryName)-ralph-ctl", isDirectory: true)
            .path
    }
}
