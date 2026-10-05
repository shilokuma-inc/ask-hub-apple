/// 起動した Discussion を、`ready-for-loop` を外し終えるまで追跡する（副作用なし）。
///
/// プロセスを起動できても、ループが始まったとは限らない（起動スクリプトが直後に失敗することがある）。
/// そこで制御用 worktree に state ファイルが現れたのを確かめてからラベルを外す。
/// ラベルを外せなかった Discussion も、ここで覚えている間は二重に起動しない。
public struct LaunchTracker: Sendable, Equatable {
    /// ループの開始を確かめられないまま起動を試す回数の上限
    public static let maxAttempts = 3

    public enum Phase: Sendable, Equatable {
        /// 起動した。state ファイルが現れるのを待っている
        case starting
        /// ループの開始を確かめた。ラベルを外し終えていない
        case started
        /// ラベルを外した。検索結果から消えるまで覚えておく
        case labelRemoved
        /// 開始を確かめられないまま終わった。次の起動を待っている
        case failed
        /// 上限まで試しても開始を確かめられなかった。人の対応を待つ
        case gaveUp
    }

    public struct Entry: Sendable, Equatable {
        /// 担当リポジトリの `fullName` を小文字にしたもの
        public var repositoryKey: String
        public var attempts: Int
        public var phase: Phase
    }

    /// ポーリングの結果として行うこと
    public enum Action: Sendable, Equatable {
        /// ループの開始を確かめた（またはラベルを外せていない）ので、`ready-for-loop` を外す
        case removeLabel(ReadyDiscussion)
        /// 開始を確かめられないままプロセスが終わった。次の起動判定で起動し直す
        case retry(ReadyDiscussion, attempts: Int)
        /// 上限まで試しても開始を確かめられなかった
        case giveUp(ReadyDiscussion, attempts: Int)
    }

    /// キーは Discussion の node id
    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    /// 起動判定で起動しない Discussion（追跡中で、起動し直す番ではないもの）
    public var blockedDiscussionIDs: Set<String> {
        Set(entries.filter { $0.value.phase != .failed }.keys)
    }

    /// 最新の検索結果とループの状態で追跡を進め、行うことを返す
    /// - Parameter preparedDiscussions: 担当リポジトリごとの、制御用 worktree の準備元の Discussion の番号
    ///   （`.claude/askhub-bootstrap.local.txt`）。state ファイルが、起動した Discussion のループのものかを見分ける
    public mutating func update(
        discussions: [ReadyDiscussion],
        statuses: [String: LoopStatus],
        preparedDiscussions: [String: Int] = [:]
    ) -> [Action] {
        // ラベルが外れた（検索に出ない）Discussion は追跡をやめる
        let current = Set(discussions.map(\.nodeID))
        entries = entries.filter { current.contains($0.key) }

        var actions: [Action] = []
        for discussion in discussions {
            guard var entry = entries[discussion.nodeID] else {
                continue
            }
            let status = statuses[entry.repositoryKey] ?? .idle
            switch entry.phase {
            case .starting:
                // 別のループ（手で再開した前の epic など）の state ファイルを、この Discussion の開始と取り違えない
                if status.stateFileExists == true, preparedDiscussions[entry.repositoryKey] == discussion.number {
                    entry.phase = .started
                    actions.append(.removeLabel(discussion))
                } else if !status.processAlive && status.stateFileExists != nil {
                    entry.phase = entry.attempts >= Self.maxAttempts ? .gaveUp : .failed
                    actions.append(entry.phase == .gaveUp
                        ? .giveUp(discussion, attempts: entry.attempts)
                        : .retry(discussion, attempts: entry.attempts))
                }
                // プロセスが生きている、または state ファイルを確かめられないときは待つ

            case .started:
                actions.append(.removeLabel(discussion))

            case .labelRemoved, .failed, .gaveUp:
                break
            }
            entries[discussion.nodeID] = entry
        }
        return actions
    }

    /// プロセスを起動した
    public mutating func recordLaunch(of discussion: ReadyDiscussion, repositoryKey: String) {
        let attempts = (entries[discussion.nodeID]?.attempts ?? 0) + 1
        entries[discussion.nodeID] = Entry(repositoryKey: repositoryKey, attempts: attempts, phase: .starting)
    }

    /// プロセスを起動できなかった（実行ファイルが無いなど）。上限に達したら諦める
    @discardableResult
    public mutating func recordLaunchFailure(of discussion: ReadyDiscussion, repositoryKey: String) -> Entry {
        let attempts = (entries[discussion.nodeID]?.attempts ?? 0) + 1
        let entry = Entry(repositoryKey: repositoryKey, attempts: attempts, phase: attempts >= Self.maxAttempts ? .gaveUp : .failed)
        entries[discussion.nodeID] = entry
        return entry
    }

    /// `repositoryKey` の起動の失敗を数えなかったことにする（利用上限で失敗した分）。
    /// 諦めた Discussion も含め、次の起動判定で起動し直す
    public mutating func forgiveFailures(repositoryKey: String) {
        for (id, entry) in entries where entry.repositoryKey == repositoryKey
            && [.starting, .failed, .gaveUp].contains(entry.phase) {
            entries[id] = Entry(repositoryKey: repositoryKey, attempts: 0, phase: .failed)
        }
    }

    /// `ready-for-loop` を外した
    public mutating func recordLabelRemoved(from discussion: ReadyDiscussion) {
        entries[discussion.nodeID]?.phase = .labelRemoved
    }
}
