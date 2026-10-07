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
    /// ループの 1 周がこれより長く進まなければ、固まったとみなして止める（既定）
    public static let defaultIterationTimeout: Duration = .seconds(90 * 60)
    /// `iterationTimeout` の下限。ビルドとテストの重いリポジトリで、まともな周回を止めないため
    public static let minimumIterationTimeout: Duration = .seconds(10 * 60)
    /// `iterationTimeout` の上限（1 日）
    public static let maximumIterationTimeout: Duration = .seconds(24 * 60 * 60)

    /// 指示として扱ってよい GitHub アカウントの login
    public let trustedAuthorLogins: [String]
    /// この PC が担当するリポジトリ
    public let repositories: [RepositoryConfig]
    public let pollInterval: Duration
    public let loopCommand: LoopCommandTemplate
    /// 依頼から Discussion を作らせるコマンド
    public let ideaCommand: IdeaCommandTemplate
    /// epic の最終 PR のコンフリクトを解消させるコマンド
    public let conflictCommand: ConflictCommandTemplate
    /// ループの 1 周（state ファイルが書き直されてから）がこれより長く進まなければ、固まったとみなして止める
    public let iterationTimeout: Duration
    /// 担当リポジトリの作成・削除の依頼（`repo-request`）に使うコマンドと場所
    public let repositoryCommands: RepositoryCommands

    public var trustedAuthors: TrustedAuthors {
        TrustedAuthors(trustedAuthorLogins)
    }

    /// `needs-answer` などを検索する organization。担当リポジトリの owner を、重ねずに設定の順で並べる
    public var orgs: [String] {
        var orgs: [String] = []
        for owner in repositories.map(\.owner)
        where !orgs.contains(where: { $0.caseInsensitiveCompare(owner) == .orderedSame }) {
            orgs.append(owner)
        }
        return orgs
    }

    public init(
        trustedAuthorLogins: [String],
        repositories: [RepositoryConfig],
        pollInterval: Duration,
        loopCommand: LoopCommandTemplate,
        ideaCommand: IdeaCommandTemplate = .standard,
        iterationTimeout: Duration = defaultIterationTimeout,
        conflictCommand: ConflictCommandTemplate? = nil,
        repositoryCommands: RepositoryCommands? = nil
    ) {
        self.trustedAuthorLogins = trustedAuthorLogins
        self.repositories = repositories
        self.pollInterval = pollInterval
        self.loopCommand = loopCommand
        self.ideaCommand = ideaCommand
        self.iterationTimeout = iterationTimeout
        self.conflictCommand = conflictCommand ?? .standard(besides: loopCommand)
        self.repositoryCommands = repositoryCommands ?? .standard(
            homeDirectory: NSHomeDirectory(),
            newCheckoutDirectory: RepositoryCommands.defaultCheckoutDirectory(for: repositories, homeDirectory: NSHomeDirectory())
        )
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

/// 担当リポジトリの作成・削除の依頼（`repo-request`）に使うコマンドと場所
public struct RepositoryCommands: Sendable, Equatable {
    /// テンプレートからリポジトリを作るコマンド。
    /// 末尾に `<テンプレート> <owner/repo> <アプリ名> <Bundle ID> <checkout のパス（clone しないなら空）> <public|private>` を足して実行する
    public let create: [String]
    /// ローカルの checkout・ループの worktree・DerivedData を消すコマンド。
    /// 末尾に `[--force] <checkout のパス> <制御用 worktree のパス>` を足して実行する
    public let remove: [String]
    /// 新しいリポジトリを clone するディレクトリ（絶対パス）。checkout は `<ここ>/<リポジトリ名>` になる
    public let newCheckoutDirectory: String

    public init(create: [String], remove: [String], newCheckoutDirectory: String) {
        self.create = create
        self.remove = remove
        self.newCheckoutDirectory = newCheckoutDirectory
    }

    /// `scripts/orchestrator/install.sh` が置く既定のコマンド
    public static func standard(homeDirectory: String, newCheckoutDirectory: String) -> Self {
        Self(
            create: ["\(homeDirectory)/.local/bin/askhub-create-repo"],
            remove: ["\(homeDirectory)/.local/bin/askhub-remove-repo"],
            newCheckoutDirectory: newCheckoutDirectory
        )
    }

    /// clone 先の既定。最初の担当リポジトリの checkout と同じ場所（無ければホームディレクトリ）
    public static func defaultCheckoutDirectory(for repositories: [RepositoryConfig], homeDirectory: String) -> String {
        guard let first = repositories.first else {
            return homeDirectory
        }
        return URL(fileURLWithPath: first.checkoutPath, isDirectory: true).deletingLastPathComponent().path
    }

    /// 新しいリポジトリの checkout のパス
    public func checkoutPath(for repositoryName: String) -> String {
        URL(fileURLWithPath: newCheckoutDirectory, isDirectory: true)
            .appendingPathComponent(repositoryName, isDirectory: true)
            .path
    }
}
