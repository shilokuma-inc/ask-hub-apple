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
}

/// 受信箱に出すもの（「要回答」の質問と「急がない」の Issue）を集める
public struct InboxFetcher: Sendable {
    private let source: any InboxSource
    private let trustedAuthors: TrustedAuthors

    public init(source: any InboxSource, trustedAuthors: TrustedAuthors) {
        self.source = source
        self.trustedAuthors = trustedAuthors
    }

    /// organization 全体の未回答の質問を、古い順に返す
    public func unansweredQuestions(orgs: [String]) async throws -> [InboxQuestion] {
        var questions: [InboxQuestion] = []
        // レート制限を考えて、Discussion / PR ごとに順番に取得する
        for subject in try await source.subjectsNeedingAnswer(orgs: orgs) {
            let threads = try await source.questionThreads(of: subject)
            questions += InboxQuestion.unanswered(in: threads, of: subject, trustedAuthors: trustedAuthors)
        }
        return questions.sorted { ($0.comment.createdAt, $0.id) < ($1.comment.createdAt, $1.id) }
    }

    /// ループの開始を待っている Discussion を、番号の古い順に返す。
    /// 信用する author が作ったものだけを扱う（public リポジトリでは誰でも Discussion を作れるため）
    public func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
        try await source.waitingDiscussions(orgs: orgs)
            .filter { trustedAuthors.contains($0.author) }
            .sorted { ($0.subject.repository, $0.subject.number) < ($1.subject.repository, $1.subject.number) }
    }

    /// 担当 PC が Claude の利用上限で待機しているリポジトリを、解除の早い順に返す
    public func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
        try await source.usageLimitedRepositories(orgs: orgs, now: now)
    }

    /// 「急がない」に出す Issue を、更新の新しい順に返す。
    /// 信用する author が作ったものだけを扱う（public リポジトリでは誰でも Issue を作れ、ラベルの付いた Issue を装えるため）
    public func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        try await source.lowPriorityIssues(orgs: orgs)
            .filter { trustedAuthors.contains($0.author) }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }
}
