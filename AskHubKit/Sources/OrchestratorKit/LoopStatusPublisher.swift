import AskHubKit
import Foundation

/// 担当リポジトリの状態用の Issue（`loop-status`）。閉じたものも含む
public struct LoopStatusIssueRecord: Sendable, Equatable {
    public let number: Int
    /// 作った author。削除済みのアカウントなどで取れなければ `nil`
    public let author: String?
    public let isOpen: Bool
    public let updatedAt: Date
    public let body: String

    public init(number: Int, author: String?, isOpen: Bool, updatedAt: Date, body: String) {
        self.number = number
        self.author = author
        self.isOpen = isOpen
        self.updatedAt = updatedAt
        self.body = body
    }
}

/// 状態用の Issue に、いつ何を書くかを決める（副作用なし）。
///
/// 本文にはリポジトリ全体の状態（`RepositoryStatusReport`）を、この PC の自動ループの状態はそのループ（Discussion）のコメントに書く
/// （[Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425) の Q1）。手動ループの有無で書き出しは止めない。
/// 書いた内容を覚えておき、状態が変わったときだけ書き換える。変わらなければ `LoopStatusReport.updateInterval` ごとに確認時刻だけを書き直す。
///
/// - 古い形（目印 1 つ）の本文を手で回しているループ（書き手が `manual`）が書いている間は、本文を上書きしない
/// - 1 つの Discussion の書き手は 1 つ。手動ループのコメントがある Discussion には書かない
/// - 自動ループのコメントは今のループのものだけを残し、前のループ（と重複）のコメントは消す
public struct LoopStatusPublisher: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// 状態用の Issue とコメントを覚えていない（または書く前に読み直す）。一覧を取得して `adopt` してから決め直す
        case lookUp
        /// 状態用の Issue を作る（本文はリポジトリ全体の状態）
        case createIssue(body: String)
        /// 本文を書き換える（閉じられていれば開き直す）
        case updateIssue(number: Int, body: String)
        /// 自動ループのコメントを作る
        case createComment(issue: Int, body: String)
        /// 自動ループのコメントを書き換える
        case updateComment(id: Int, body: String)
        /// 前のループ・重複した自動ループのコメントを消す
        case deleteComment(id: Int)
    }

    /// オーケストレーターが書いた、ループのコメント
    struct Comment: Sendable, Equatable {
        var id: Int
        var report: LoopStatusReport
    }

    struct Entry: Sendable, Equatable {
        var number: Int?
        /// 最後に書いた（Issue から読んだ）本文。閉じていれば `.unreadable`（次は必ず書く）
        var body: LoopStatusBoard.Body = .unreadable
        /// オーケストレーターが書いたループのコメント（作った順）
        var comments: [Comment] = []
        /// ほかの書き手（手動ループなど）のコメントの状態。キーは Discussion の番号
        var otherWriters: [Int: LoopStatusReport] = [:]
    }

    /// キーは担当リポジトリの `fullName` を小文字にしたもの
    private(set) var entries: [String: Entry] = [:]
    /// レート制限で `Retry-After` を示されたリポジトリと、次に試してよい時刻
    private(set) var retryAt: [String: Date] = [:]

    public init() {}

    /// 書くこと。空なら書かない
    /// - Parameters:
    ///   - repository: 本文に書くリポジトリ全体の状態
    ///   - loop: この PC の自動ループの状態。Discussion の番号が無ければ（ループが無い・ゴール元の記録が無い）コメントに書かない
    ///   - manualLoopOpen: このリポジトリに手動ループ（open な `manual-loop` の Discussion）がある。
    ///     手動ループが書いた状態は、確認時刻が古くなっても上書きしない（担当者の情報を消さないため。アプリが古さを知らせる）
    public func actions(
        repositoryKey key: String,
        repository: RepositoryStatusReport,
        loop: LoopStatusReport,
        now: Date,
        manualLoopOpen: Bool = false
    ) -> [Action] {
        // ポーリングの間隔より長い `Retry-After` を示されたら、それまで一覧も本文も取りに行かない
        if let retryAt = retryAt[key], now < retryAt {
            return []
        }
        guard let entry = entries[key] else {
            return [.lookUp]
        }
        guard let number = entry.number else {
            return [.createIssue(body: repository.issueBody)]
        }
        var actions: [Action] = []
        if let body = bodyAction(entry, number: number, repository: repository, now: now, manualLoopOpen: manualLoopOpen) {
            actions.append(body)
        }
        let current = loop.discussion.flatMap { discussion in
            isWrittenByOtherWriter(entry.otherWriters[discussion], now: now, manualLoopOpen: manualLoopOpen) ? nil : discussion
        }
        let kept = current.flatMap { discussion in entry.comments.last { $0.report.discussion == discussion } }
        if current != nil {
            if let kept {
                if !Self.isFresh(kept.report, comparedTo: loop, now: now) {
                    actions.append(.updateComment(id: kept.id, body: loop.commentBody))
                }
            } else {
                actions.append(.createComment(issue: number, body: loop.commentBody))
            }
        }
        for comment in entry.comments where comment.id != kept?.id {
            actions.append(.deleteComment(id: comment.id))
        }
        return actions
    }

    private func bodyAction(
        _ entry: Entry, number: Int, repository: RepositoryStatusReport, now: Date, manualLoopOpen: Bool
    ) -> Action? {
        switch entry.body {
        case let .loop(legacy) where legacy.writer == .manual && (Self.isWrittenByManualLoop(legacy, now: now) || manualLoopOpen):
            // 古い形の手動ループの本文は上書きしない（ralph-kit が新しい形で書くようになるまで、手動ループはここに書く）
            return nil

        case let .repository(previous)
            where previous.hasSameStatus(as: repository) && now.timeIntervalSince(previous.checkedAt) < LoopStatusReport.updateInterval:
            return nil

        default:
            return .updateIssue(number: number, body: repository.issueBody)
        }
    }

    /// ほかの書き手（手動ループ）がその Discussion を書いている
    private func isWrittenByOtherWriter(_ report: LoopStatusReport?, now: Date, manualLoopOpen: Bool) -> Bool {
        guard let report else {
            return false
        }
        return report.writer != .manual || Self.isWrittenByManualLoop(report, now: now) || manualLoopOpen
    }

    /// 前に書いた状態と同じで、書き直しの間隔より前か
    private static func isFresh(_ previous: LoopStatusReport, comparedTo report: LoopStatusReport, now: Date) -> Bool {
        previous.hasSameStatus(as: report) && now.timeIntervalSince(previous.checkedAt) < LoopStatusReport.updateInterval
    }

    /// 書き換える前に、Issue とコメントを読み直すか（作るだけなら読み直さない）
    public static func needsLookUp(before actions: [Action]) -> Bool {
        actions.contains { action in
            switch action {
            case .createIssue: false
            case .lookUp, .updateIssue, .createComment, .updateComment, .deleteComment: true
            }
        }
    }

    /// 手で回しているループが書いている（書き手が `manual` で、確認時刻が `LoopStatusReport.freshness` 以内）。
    /// 手で回すループが止まって確認時刻が古くなれば、オーケストレーターが書き直す
    public static func isWrittenByManualLoop(_ report: LoopStatusReport?, now: Date) -> Bool {
        guard let report, report.writer == .manual else {
            return false
        }
        return report.isAssigned(now: now)
    }

    /// 使う状態用の Issue。信用する author が作ったもののうち、open なものの最も新しく更新されたもの、
    /// 無ければ閉じたものの最も新しいもの（開き直して使う）
    public static func issue(in issues: [LoopStatusIssueRecord], trustedAuthors: TrustedAuthors) -> LoopStatusIssueRecord? {
        issues
            .filter { trustedAuthors.contains($0.author) }
            .max { ($0.isOpen ? 1 : 0, $0.updatedAt, $0.number) < ($1.isOpen ? 1 : 0, $1.updatedAt, $1.number) }
    }

    /// 取得した状態用の Issue と、使う Issue（`issue(in:trustedAuthors:)`）のコメントから、書いた内容を覚える。
    /// コメントは信用する author の、Discussion の番号のある目印だけを読む（どのループかは author ではなく目印の中身で見分ける）
    public mutating func adopt(
        _ issues: [LoopStatusIssueRecord],
        comments: [LoopStatusComment],
        repositoryKey key: String,
        trustedAuthors: TrustedAuthors
    ) {
        guard let issue = Self.issue(in: issues, trustedAuthors: trustedAuthors) else {
            entries[key] = Entry(number: nil)
            return
        }
        var entry = Entry(number: issue.number)
        if issue.isOpen {
            entry.body = LoopStatusBoard(issueBody: issue.body, comments: [], trustedAuthors: trustedAuthors).body
        }
        for comment in comments.sorted(by: { $0.id < $1.id }) where trustedAuthors.contains(comment.author) {
            guard let report = LoopStatusReport.parse(comment.body), let discussion = report.discussion else {
                continue
            }
            if report.writer == .orchestrator {
                entry.comments.append(Comment(id: comment.id, report: report))
            } else if entry.otherWriters[discussion].map({ $0.checkedAt <= report.checkedAt }) ?? true {
                entry.otherWriters[discussion] = report
            }
        }
        entries[key] = entry
    }

    /// 状態用の Issue を作った（コメントはまだ無い）
    public mutating func recordIssueCreated(number: Int, body: RepositoryStatusReport, repositoryKey key: String) {
        entries[key] = Entry(number: number, body: .repository(body))
    }

    /// 本文を書き終えた
    public mutating func recordBodyWritten(_ body: RepositoryStatusReport, repositoryKey key: String) {
        entries[key]?.body = .repository(body)
    }

    /// 自動ループのコメントを書き終えた（作った・書き換えた）
    public mutating func recordCommentWritten(_ report: LoopStatusReport, id: Int, repositoryKey key: String) {
        guard var entry = entries[key] else {
            return
        }
        if let index = entry.comments.firstIndex(where: { $0.id == id }) {
            entry.comments[index].report = report
        } else {
            entry.comments.append(Comment(id: id, report: report))
        }
        entries[key] = entry
    }

    /// コメントを消し終えた
    public mutating func recordCommentDeleted(id: Int, repositoryKey key: String) {
        entries[key]?.comments.removeAll { $0.id == id }
    }

    /// 書けなかった。次のポーリングで一覧から取り直す（Issue・コメントが消された・移された場合に備える）。
    /// レート制限なら、`retryAfter` が過ぎるまで試さない
    public mutating func forget(repositoryKey key: String, retryAfter: Duration? = nil, now: Date = Date()) {
        entries[key] = nil
        retryAt[key] = retryAfter.map { now.addingTimeInterval(TimeInterval($0.components.seconds)) }
    }
}
