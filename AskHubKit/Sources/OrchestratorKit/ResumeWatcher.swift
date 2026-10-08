import AskHubKit

/// `needs-answer` の Discussion / PR と、その中の質問ごとの回答状況
public struct AnswerSnapshot: Sendable, Equatable {
    public let subject: InboxSubject
    /// 信用する author の質問のコメントの node id と、回答済みか
    public let questions: [Question]
    /// 手で回す Discussion か（信用する author の Discussion に `manual-loop` が付いている）
    public let isManualLoop: Bool

    public struct Question: Sendable, Equatable {
        public let id: String
        public let isAnswered: Bool

        public init(id: String, isAnswered: Bool) {
            self.id = id
            self.isAnswered = isAnswered
        }
    }

    public init(subject: InboxSubject, questions: [Question], isManualLoop: Bool = false) {
        self.subject = subject
        self.questions = questions
        self.isManualLoop = isManualLoop
    }

    /// スレッドから、信用する author の質問とその回答状況を読み取る（`docs/protocol.md` の「回答済みの判定」）
    public init(subject: InboxSubject, threads: [QuestionThread], trustedAuthors: TrustedAuthors) {
        let questions = threads.compactMap { thread -> Question? in
            guard trustedAuthors.question(in: thread.comment.body, author: thread.comment.author) != nil else {
                return nil
            }
            return Question(id: thread.comment.nodeID, isAnswered: trustedAuthors.isAnswered(replyAuthors: thread.replyAuthors))
        }
        self.init(subject: subject, questions: questions, isManualLoop: subject.isManualLoop(trustedAuthors: trustedAuthors))
    }

    /// 質問が 1 つ以上あり、すべて回答済みか
    public var isFullyAnswered: Bool {
        !questions.isEmpty && questions.allSatisfy(\.isAnswered)
    }
}

/// ask への回答を見て、止まっているループを再開する（副作用なし）。
///
/// 回答済みの質問はメモリ上で覚え、新しく回答が付いた PR のリポジトリだけを再開する
/// （回答済みの質問は回答済みのまま残るため、覚えておかないとループが終わるたびに再開してしまう）。
/// オーケストレーターを再起動すると忘れるので、その直後は回答済みの ask が残る PR のリポジトリを 1 回再開しうる。
public struct ResumeWatcher: Sendable, Equatable {
    /// ループの開始を確かめられないまま再開を試す回数の上限
    public static let maxAttempts = 3

    public enum Phase: Sendable, Equatable {
        /// 再開が要る。ループが止まっていれば起動する
        case waiting
        /// 起動した。state ファイルが現れるのを待っている
        case launched
        /// 上限まで試しても開始を確かめられなかった。新しい回答が付くまで再開しない
        case gaveUp
    }

    public struct Entry: Sendable, Equatable {
        public var attempts: Int
        public var phase: Phase
    }

    public enum Action: Sendable, Equatable {
        /// すべての質問に回答が付いたので `needs-answer` を外す（Discussion なら `ready-for-loop` を付ける）
        case removeNeedsAnswer(InboxSubject)
        /// 手で回す Discussion の質問がすべて回答されたので、`ready-for-loop` は付けずに `needs-answer` だけを外す
        case removeNeedsAnswerOfManualLoop(InboxSubject)
        /// 止まっているループを再開する（キーは担当リポジトリの `fullName` を小文字にしたもの）
        case resume(repositoryKey: String)
        /// 上限まで試しても再開を確かめられなかった
        case giveUp(repositoryKey: String, attempts: Int)
    }

    /// 回答済みとして扱い終えた質問の node id
    public private(set) var seenAnswers: Set<String> = []
    /// 再開を待っているリポジトリ
    public private(set) var resumes: [String: Entry] = [:]

    public init() {}

    /// 担当リポジトリの `needs-answer` の一覧とループの状態から、行うことを返す
    /// - Parameters:
    ///   - snapshots: 担当リポジトリのものだけを渡す
    ///   - manualLoopRepositories: 手動ループ（open な `manual-loop` の Discussion）があるリポジトリ（`fullName` の小文字）。
    ///     ループは担当者の Mac で動いているので、この PC からは再開しない（担当者がアプリの知らせを見て再開する）
    public mutating func update(
        snapshots: [AnswerSnapshot],
        statuses: [String: LoopStatus],
        manualLoopRepositories: Set<String> = []
    ) -> [Action] {
        for key in manualLoopRepositories {
            resumes[key] = nil
        }
        var actions = recordAnswers(in: snapshots, skipping: manualLoopRepositories)
        for key in resumes.keys.sorted() {
            guard let entry = resumes[key] else {
                continue
            }
            let (next, action) = Self.advance(entry, key: key, status: statuses[key] ?? .idle)
            resumes[key] = next
            actions += action.map { [$0] } ?? []
        }
        return actions
    }

    /// 新しく付いた回答を覚え、PR の回答なら再開待ちにする。すべて回答済みの Discussion / PR はラベルを外す
    private mutating func recordAnswers(in snapshots: [AnswerSnapshot], skipping manualLoopRepositories: Set<String>) -> [Action] {
        var actions: [Action] = []
        for snapshot in snapshots {
            let newlyAnswered = snapshot.questions.filter { $0.isAnswered && !seenAnswers.contains($0.id) }
            let key = snapshot.subject.repository.lowercased()
            // Discussion（※1）の回答では再開しない。ループは「回答を確定してループを始める」（ready-for-loop）で始まる
            if snapshot.subject.kind == .pullRequest && !newlyAnswered.isEmpty && !manualLoopRepositories.contains(key) {
                if resumes[key] == nil || resumes[key]?.phase == .gaveUp {
                    resumes[key] = Entry(attempts: 0, phase: .waiting)
                }
            }
            seenAnswers.formUnion(newlyAnswered.map(\.id))
            if snapshot.isFullyAnswered {
                actions.append(
                    snapshot.isManualLoop ? .removeNeedsAnswerOfManualLoop(snapshot.subject) : .removeNeedsAnswer(snapshot.subject)
                )
            }
        }
        return actions
    }

    /// 再開待ちのリポジトリを 1 つ進める。戻り値の `Entry` が `nil` なら再開待ちを終える
    private static func advance(_ entry: Entry, key: String, status: LoopStatus) -> (Entry?, Action?) {
        var entry = entry
        switch entry.phase {
        case .gaveUp:
            return (entry, nil)

        case .launched:
            if status.stateFileExists == true {
                // 再開を確かめた
                return (nil, nil)
            }
            if status.processAlive || status.stateFileExists == nil {
                return (entry, nil)
            }
            // 開始を確かめられないままプロセスが終わったので、起動し直す
            entry.phase = .waiting

        case .waiting:
            if status.processAlive || status.stateFileExists == true {
                // ループが動いている。回答はループ自身が拾う
                return (nil, nil)
            }
            if status.stateFileExists == nil {
                return (entry, nil)
            }
        }
        if entry.attempts >= maxAttempts {
            entry.phase = .gaveUp
            return (entry, .giveUp(repositoryKey: key, attempts: entry.attempts))
        }
        return (entry, .resume(repositoryKey: key))
    }

    /// 再開のためにループを起動した
    public mutating func recordLaunch(repositoryKey key: String) {
        let attempts = (resumes[key]?.attempts ?? 0) + 1
        resumes[key] = Entry(attempts: attempts, phase: .launched)
    }

    /// 再開のための起動に失敗した（実行ファイルが無いなど）。上限に達したら諦める
    @discardableResult
    public mutating func recordLaunchFailure(repositoryKey key: String) -> Entry {
        let attempts = (resumes[key]?.attempts ?? 0) + 1
        let entry = Entry(attempts: attempts, phase: attempts >= Self.maxAttempts ? .gaveUp : .waiting)
        resumes[key] = entry
        return entry
    }
}
