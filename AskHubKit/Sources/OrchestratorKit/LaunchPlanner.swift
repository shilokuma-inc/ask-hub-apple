import AskHubKit
import Foundation

/// `ready-for-loop` が付いた Discussion（回答が確定し、ループを始めてよい）
public struct ReadyDiscussion: Sendable, Equatable {
    /// GraphQL の node id。ラベルを外すのに使う
    public let nodeID: String
    /// `owner/repo`
    public let repository: String
    public let number: Int
    public let title: String
    public let url: URL
    /// 削除済みのユーザーでは `nil`
    public let author: String?
    /// `ready-for-loop` ラベルの node id
    public let readyLabelID: String

    public init(
        nodeID: String,
        repository: String,
        number: Int,
        title: String,
        url: URL,
        author: String?,
        readyLabelID: String
    ) {
        self.nodeID = nodeID
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.readyLabelID = readyLabelID
    }
}

/// 担当リポジトリのループの状態
public struct LoopStatus: Sendable, Equatable {
    /// 制御用 worktree に `.claude/ralph-loop.local.md` があるか
    public let stateFileExists: Bool
    /// このオーケストレーターが起動したプロセスが生きているか
    public let processAlive: Bool

    public init(stateFileExists: Bool, processAlive: Bool) {
        self.stateFileExists = stateFileExists
        self.processAlive = processAlive
    }

    public static let idle = Self(stateFileExists: false, processAlive: false)
}

/// `ready-for-loop` の Discussion ごとの判定
public enum LaunchDecision: Sendable, Equatable {
    /// ループを起動して `ready-for-loop` を外す
    case launch(ReadyDiscussion, RepositoryConfig)
    /// 今回は起動しない。ラベルは残し、次のポーリングで判定し直す
    case skip(ReadyDiscussion, SkipReason)

    public enum SkipReason: Sendable, Equatable {
        /// この PC の担当ではない（別の PC のオーケストレーターが扱う）
        case notAssigned
        /// Discussion の author が信用する author ではない
        case untrustedAuthor
        /// 起動したループがまだ動いている
        case loopRunning
        /// ループの state ファイルが残っている（実行中か、終了後に片付いていない）
        case loopStateRemains
        /// 同じリポジトリの別の Discussion を先に起動する
        case waitingForAnotherDiscussion(number: Int)
    }
}

/// `ready-for-loop` の Discussion から、起動するループを決める（副作用なし）
public enum LaunchPlanner {
    /// - Parameter statuses: 担当リポジトリの `fullName` を小文字にしたキーごとのループの状態。無いものは停止中とみなす
    public static func decide(
        _ discussions: [ReadyDiscussion],
        config: OrchestratorConfig,
        statuses: [String: LoopStatus]
    ) -> [LaunchDecision] {
        // 1 つのリポジトリで同時に動かすループは 1 つ。番号の小さい（先に作られた）Discussion から起動する
        var launching: [String: Int] = [:]
        return discussions.sorted { $0.number < $1.number }.map { discussion in
            guard let repository = config.repository(named: discussion.repository) else {
                return .skip(discussion, .notAssigned)
            }
            // public リポジトリでは誰でも Discussion を作れるため、信用する author のものだけを指示として扱う
            guard config.trustedAuthors.contains(discussion.author) else {
                return .skip(discussion, .untrustedAuthor)
            }
            let key = repository.fullName.lowercased()
            if let first = launching[key] {
                return .skip(discussion, .waitingForAnotherDiscussion(number: first))
            }
            let status = statuses[key] ?? .idle
            if status.processAlive {
                return .skip(discussion, .loopRunning)
            }
            if status.stateFileExists {
                return .skip(discussion, .loopStateRemains)
            }
            launching[key] = discussion.number
            return .launch(discussion, repository)
        }
    }
}
