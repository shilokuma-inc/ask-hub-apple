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
    /// `manual-loop`（手で回す）が付いているか
    public let isManualLoop: Bool

    public init(
        nodeID: String,
        repository: String,
        number: Int,
        title: String,
        url: URL,
        author: String?,
        readyLabelID: String,
        isManualLoop: Bool = false
    ) {
        self.nodeID = nodeID
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.readyLabelID = readyLabelID
        self.isManualLoop = isManualLoop
    }
}

/// 担当リポジトリのループの状態
public struct LoopStatus: Sendable, Equatable {
    /// 制御用 worktree に `.claude/ralph-loop.local.md` があるか。
    /// アクセス権が無いなどで確かめられないときは `nil`（無いとはみなさない）
    public let stateFileExists: Bool?
    /// このオーケストレーターが起動したプロセスが生きているか
    public let processAlive: Bool
    /// ループが異常終了した（state ファイルが残っているのに、記録した PID のプロセスが居ない）。
    /// `ralph-stop.sh` で止めた・promise で終わったループは state ファイルが消えるので `false`
    public let stalled: Bool

    public init(stateFileExists: Bool?, processAlive: Bool, stalled: Bool = false) {
        self.stateFileExists = stateFileExists
        self.processAlive = processAlive
        self.stalled = stalled
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
        /// 手で回す Discussion（`manual-loop`）。ループは手で始めるので、オーケストレーターは起動しない
        case manualLoop
        /// 同じリポジトリに手で回す Discussion（open な `manual-loop`）があり、その epic が終わるのを待っている
        case manualLoopInProgress(number: Int)
        /// 起動したループがまだ動いている
        case loopRunning
        /// ループの state ファイルが残っている（実行中か、終了後に片付いていない）
        case loopStateRemains
        /// state ファイルの有無を確かめられない（アクセス権が無いなど）
        case loopStatusUnknown
        /// 同じリポジトリの別の Discussion を先に起動する
        case waitingForAnotherDiscussion(number: Int)
        /// 起動済みで、ループの開始の確認かラベルの削除を待っている（`LaunchTracker`）
        case alreadyLaunched
        /// 同じリポジトリの途中の epic（未完了のタスクが残っている）が終わるのを待っている
        case epicInProgress
    }
}

/// `ready-for-loop` の Discussion から、起動するループを決める（副作用なし）
public enum LaunchPlanner {
    /// - Parameters:
    ///   - statuses: 担当リポジトリの `fullName` を小文字にしたキーごとのループの状態。無いものは停止中とみなす
    ///   - excluding: 起動済みで追跡中の Discussion の node id
    ///   - epicsInProgress: 途中の epic がある担当リポジトリ（`fullName` を小文字にしたもの）
    ///   - manualLoops: open な `manual-loop` の Discussion。信用する author のものがあるリポジトリでは起動しない
    public static func decide(
        _ discussions: [ReadyDiscussion],
        config: OrchestratorConfig,
        statuses: [String: LoopStatus],
        excluding launched: Set<String> = [],
        epicsInProgress: Set<String> = [],
        manualLoops: [ManualLoopDiscussion] = [],
        trust: TrustDirectory? = nil
    ) -> [LaunchDecision] {
        // 省略したときは設定の一覧だけを信用する
        let trust = trust ?? TrustDirectory(base: config.trustedAuthors)
        // 1 つのリポジトリで同時に動かすループは 1 つ。番号の小さい（先に作られた）Discussion から起動する
        var launching: [String: Int] = [:]
        let manual = manualLoopNumbers(manualLoops, trust: trust)
        return discussions.sorted { $0.number < $1.number }.map { discussion in
            guard let repository = config.repository(named: discussion.repository) else {
                return .skip(discussion, .notAssigned)
            }
            if launched.contains(discussion.nodeID) {
                return .skip(discussion, .alreadyLaunched)
            }
            // public リポジトリでは誰でも Discussion を作れるため、信用する author のものだけを指示として扱う
            guard trust.authors(for: discussion.repository).contains(discussion.author) else {
                return .skip(discussion, .untrustedAuthor)
            }
            let key = repository.fullName.lowercased()
            if let reason = manualLoopReason(for: discussion, manualLoopNumber: manual[key]) {
                return .skip(discussion, reason)
            }
            if let first = launching[key] {
                return .skip(discussion, .waitingForAnotherDiscussion(number: first))
            }
            let status = statuses[key] ?? .idle
            if status.processAlive {
                return .skip(discussion, .loopRunning)
            }
            // 起動スクリプトも断るが、起動の失敗として数えると上限で諦めてしまい、epic が終わっても始まらない
            if epicsInProgress.contains(key) {
                return .skip(discussion, .epicInProgress)
            }
            switch status.stateFileExists {
            case true:
                return .skip(discussion, .loopStateRemains)

            case nil:
                // 動いているループを二重に起動しないよう、確かめられないときは起動しない
                return .skip(discussion, .loopStatusUnknown)

            case false:
                break
            }
            launching[key] = discussion.number
            return .launch(discussion, repository)
        }
    }

    /// 担当リポジトリごとの、信用する author の open な `manual-loop` の Discussion の最も小さい番号。
    /// 手で回す epic はオーケストレーターから見えないので、Discussion が open なあいだは終わっていないとみなす
    /// （最終 PR のマージで Discussion は閉じられる）。信用外の author の `manual-loop` は無視する
    private static func manualLoopNumbers(_ discussions: [ManualLoopDiscussion], trust: TrustDirectory) -> [String: Int] {
        var numbers: [String: Int] = [:]
        for discussion in discussions where trust.authors(for: discussion.repository).contains(discussion.author) {
            let key = discussion.repository.lowercased()
            numbers[key] = min(numbers[key] ?? discussion.number, discussion.number)
        }
        return numbers
    }

    /// 手で回すループと二重に進めないよう、起動しない理由。手で回す Discussion そのものか、同じリポジトリに手で回す epic がある
    private static func manualLoopReason(for discussion: ReadyDiscussion, manualLoopNumber: Int?) -> LaunchDecision.SkipReason? {
        if discussion.isManualLoop {
            return .manualLoop
        }
        return manualLoopNumber.map { .manualLoopInProgress(number: $0) }
    }
}
