import Foundation

/// 状態用の Issue（`loop-status`）のコメント 1 つ分。author の判定前の取得結果
public struct LoopStatusComment: Sendable, Equatable {
    /// REST のコメントの id（GraphQL の `databaseId`）。書き手が自分のループのコメントを書き換えるのに使う
    public var id: Int
    /// 書いた author。削除済みのアカウントなどで取れなければ `nil`
    public var author: String?
    public var updatedAt: Date
    public var body: String

    public init(id: Int, author: String?, updatedAt: Date, body: String) {
        self.id = id
        self.author = author
        self.updatedAt = updatedAt
        self.body = body
    }
}

/// 状態用の Issue 1 つ（本文とループごとのコメント）から読んだ、リポジトリのループの状態。
///
/// 状態用の Issue はリポジトリに 1 つのまま、ループ（Discussion）ごとに 1 つのコメントを置き、書き手は自分のループのコメントだけを書き換える
/// （[Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425) の Q1）。
/// コメントには `LoopStatusReport` の目印を `discussion` 付きで書き、本文はオーケストレーターがリポジトリ全体の状態（`RepositoryStatusReport`）に使う。
/// kit 1.3 までの手動ループは古い形（本文に `LoopStatusReport` の目印 1 つ）で書くので、古い形の本文も 1 つのループとして読む（ralph-kit 1.4.0 からはコメントに書く）。
///
/// public リポジトリでは誰でもコメントできるので、信用する author のコメントだけを読む。同じアカウントがオーケストレーターと手動ループの両方の
/// 書き手になりうるので、どのループのものかは author ではなく目印の Discussion の番号で見分ける。
/// 本文は、信用する author が作った Issue のものを渡す（Issue の選び方は呼び出し側）。詳細は `docs/protocol.md` の「ループの状態」を参照
public struct LoopStatusBoard: Sendable, Equatable {
    /// 本文の形
    public enum Body: Sendable, Equatable {
        /// 新しい形（リポジトリ全体の状態）
        case repository(RepositoryStatusReport)
        /// 古い形（ループの状態の目印 1 つ）。`writer` が `manual` なら手動ループ、`orchestrator` なら自動ループ
        case loop(LoopStatusReport)
        /// 目印が先頭に無い・形式が崩れている（人が編集したなど）
        case unreadable
    }

    /// ループの状態をどこから読んだか
    public enum Source: Sendable, Equatable {
        /// 古い形の本文
        case issueBody
        /// ループのコメント（REST のコメントの id）
        case comment(id: Int)
    }

    /// ループ 1 つ分の状態
    public struct Loop: Sendable, Equatable {
        public var report: LoopStatusReport
        public var source: Source

        public init(report: LoopStatusReport, source: Source) {
            self.report = report
            self.source = source
        }

        /// ゴール元の Discussion の番号。古い形の本文で記録が無ければ `nil`
        public var discussion: Int? {
            report.discussion
        }
    }

    public var body: Body
    /// ループごとの状態。Discussion の番号の順で、同じ Discussion は 1 つにまとめてある。
    /// 古い形の本文で Discussion の番号が無いループは最後に置く
    public var loops: [Loop]

    public init(body: Body, loops: [Loop]) {
        self.body = body
        self.loops = loops
    }

    /// 状態用の Issue の本文とコメントから読む。
    ///
    /// 同じ Discussion の状態が複数あれば、`checkedAt` が最も新しいものを使う。`checkedAt` が同じなら、
    /// 古い形の本文よりコメントを、コメント同士では更新の新しいものを使う
    /// - Parameters:
    ///   - issueBody: 状態用の Issue の本文（信用する author が作った Issue のもの）
    ///   - comments: 状態用の Issue のコメント（author を問わない。信用する author のものだけを読む）
    public init(issueBody: String, comments: [LoopStatusComment], trustedAuthors: TrustedAuthors) {
        let body = Self.body(of: issueBody)
        var candidates: [Candidate] = []
        if case let .loop(report) = body {
            candidates.append(Candidate(loop: Loop(report: report, source: .issueBody), comment: nil))
        }
        for comment in comments where trustedAuthors.contains(comment.author) {
            // コメントはループごとに置くので、Discussion の番号の無い目印は読まない
            guard let report = LoopStatusReport.parse(comment.body), report.discussion != nil else {
                continue
            }
            candidates.append(Candidate(loop: Loop(report: report, source: .comment(id: comment.id)), comment: comment))
        }
        var newest: [Int: Candidate] = [:]
        var withoutDiscussion: [Loop] = []
        for candidate in candidates {
            guard let discussion = candidate.loop.discussion else {
                withoutDiscussion.append(candidate.loop)
                continue
            }
            if let current = newest[discussion], !current.isOlder(than: candidate) {
                continue
            }
            newest[discussion] = candidate
        }
        self.init(
            body: body,
            loops: newest.sorted { $0.key < $1.key }.map(\.value.loop) + withoutDiscussion
        )
    }

    /// リポジトリ全体の状態（新しい形の本文）。古い形・読めない本文なら `nil`
    public var repository: RepositoryStatusReport? {
        guard case let .repository(report) = body else {
            return nil
        }
        return report
    }

    /// その Discussion のループの状態。無ければ `nil`
    public func loop(discussion: Int) -> Loop? {
        loops.first { $0.discussion == discussion }
    }

    private static func body(of issueBody: String) -> Body {
        if let report = RepositoryStatusReport.parse(issueBody) {
            return .repository(report)
        }
        if let report = LoopStatusReport.parse(issueBody) {
            return .loop(report)
        }
        return .unreadable
    }

    /// 同じ Discussion の状態の候補
    private struct Candidate {
        let loop: Loop
        /// 読んだコメント。古い形の本文なら `nil`
        let comment: LoopStatusComment?

        /// `other` のほうを使うべきか
        func isOlder(than other: Self) -> Bool {
            let checkedAt = loop.report.checkedAt
            let otherCheckedAt = other.loop.report.checkedAt
            if checkedAt != otherCheckedAt {
                return checkedAt < otherCheckedAt
            }
            // 確かめた時刻が同じなら、古い形の本文よりコメント、コメント同士は更新の新しいもの（さらに同じなら id の大きいもの）
            guard let otherComment = other.comment else {
                return false
            }
            guard let comment else {
                return true
            }
            return (comment.updatedAt, comment.id) < (otherComment.updatedAt, otherComment.id)
        }
    }
}
