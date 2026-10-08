import Foundation

/// 受信箱の取得元。テストでは差し替える
public protocol InboxSource: Sendable {
    /// `needs-answer` が付いた open な Discussion と PR
    func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject]
    /// Discussion / PR の、質問かもしれないスレッドの一覧
    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread]
    /// `decision-log` / `needs-verify` が付いた open な Issue
    func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue]
    /// `ready-for-loop` が付いた open な Discussion と、そのリポジトリの担当の印
    func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion]
    /// 担当 PC が Claude の利用上限で待機しているリポジトリ（担当の印から読む）
    func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository]
    /// `manual-loop` が付いた open な Discussion と、そのコメント（手動ループ）
    func manualLoopRecords(orgs: [String]) async throws -> [ManualLoopRecord]
}

extension InboxSource {
    /// 取得しない取得元（テストの差し替えなど）では空
    public func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
        []
    }

    /// 取得しない取得元（テストの差し替えなど）では空
    public func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
        []
    }

    /// 取得しない取得元（テストの差し替えなど）では空
    public func manualLoopRecords(orgs: [String]) async throws -> [ManualLoopRecord] {
        []
    }
}

/// 受信箱に出すもの（「要対応」の要回答の質問と「任意判断」「実機確認」の Issue）を集める
public struct InboxFetcher: Sendable {
    private let source: any InboxSource
    private let trust: any TrustedAuthorsResolving

    /// - Parameter trustedAuthors: リポジトリごとの信用する author（固定の一覧なら `TrustedAuthors` をそのまま渡す）
    public init(source: any InboxSource, trustedAuthors: any TrustedAuthorsResolving) {
        self.source = source
        self.trust = trustedAuthors
    }

    /// organization 全体の未回答の質問を、古い順に返す
    public func unansweredQuestions(orgs: [String]) async throws -> [InboxQuestion] {
        var questions: [InboxQuestion] = []
        // レート制限を考えて、Discussion / PR ごとに順番に取得する
        for subject in try await source.subjectsNeedingAnswer(orgs: orgs) {
            let threads = try await source.questionThreads(of: subject)
            let trusted = await trust.trustedAuthors(for: subject.repository)
            questions += InboxQuestion.unanswered(in: threads, of: subject, trustedAuthors: trusted)
        }
        return questions.sorted { ($0.comment.createdAt, $0.id) < ($1.comment.createdAt, $1.id) }
    }

    /// ループの開始を待っている Discussion を、番号の古い順に返す。
    /// 信用する author が作ったものだけを扱う（public リポジトリでは誰でも Discussion を作れるため）
    public func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
        var trusted: [WaitingDiscussion] = []
        for discussion in try await source.waitingDiscussions(orgs: orgs)
        where await trust.trustedAuthors(for: discussion.subject.repository).contains(discussion.author) {
            trusted.append(discussion)
        }
        return trusted.sorted { ($0.subject.repository, $0.subject.number) < ($1.subject.repository, $1.subject.number) }
    }

    /// 担当 PC が Claude の利用上限で待機しているリポジトリを、解除の早い順に返す
    public func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
        try await source.usageLimitedRepositories(orgs: orgs, now: now)
    }

    /// 「任意判断」「実機確認」に出す Issue を、更新の新しい順に返す。
    /// 信用する author が作ったものだけを扱う（public リポジトリでは誰でも Issue を作れ、ラベルの付いた Issue を装えるため）
    public func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        var trusted: [InboxIssue] = []
        for issue in try await source.lowPriorityIssues(orgs: orgs)
        where await trust.trustedAuthors(for: issue.repository).contains(issue.author) {
            trusted.append(issue)
        }
        return trusted.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    /// 手動ループの epic を、リポジトリと番号の順に返す。
    /// 信用する author が作った Discussion だけを扱い、担当者は信用する author の担当のコメントのうち最後のものから読む
    public func manualLoopEpics(orgs: [String]) async throws -> [ManualLoopEpic] {
        var epics: [ManualLoopEpic] = []
        for record in try await source.manualLoopRecords(orgs: orgs) {
            let trusted = await trust.trustedAuthors(for: record.subject.repository)
            guard trusted.contains(record.subject.author) else {
                continue
            }
            let comments = record.comments.map { (author: $0.author, body: $0.body) }
            epics.append(ManualLoopEpic(
                subject: record.subject,
                assignee: ManualLoopAssignment.latestAssignee(in: comments, trustedAuthors: trusted)
            ))
        }
        return epics.sorted { ($0.subject.repository, $0.subject.number) < ($1.subject.repository, $1.subject.number) }
    }

    /// `needs-answer` が付いた open な Discussion と PR（author を問わない。手動ループの回答待ちの PR が残っているかの判定に使う）
    public func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
        try await source.subjectsNeedingAnswer(orgs: orgs)
    }

    /// `repository` で信用する author（画面で、手で回す印を付けてよいかの判定に使う）
    public func trustedAuthors(for repository: String) async -> TrustedAuthors {
        await trust.trustedAuthors(for: repository)
    }
}
