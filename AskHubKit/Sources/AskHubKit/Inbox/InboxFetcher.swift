/// 受信箱の取得元。テストでは差し替える
public protocol InboxSource: Sendable {
    /// `needs-answer` が付いた open な Discussion と PR
    func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject]
    /// Discussion / PR の、質問かもしれないスレッドの一覧
    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread]
    /// `decision-log` / `needs-verify` が付いた open な Issue
    func lowPriorityIssues(org: String) async throws -> [InboxIssue]
}

/// 受信箱に出すもの（「要回答」の質問と「急がない」の Issue）を集める
public struct InboxFetcher: Sendable {
    private let source: any InboxSource
    private let trustedAuthors: TrustedAuthors

    public init(source: any InboxSource, trustedAuthors: TrustedAuthors) {
        self.source = source
        self.trustedAuthors = trustedAuthors
    }

    /// org 全体の未回答の質問を、古い順に返す
    public func unansweredQuestions(org: String) async throws -> [InboxQuestion] {
        var questions: [InboxQuestion] = []
        // レート制限を考えて、Discussion / PR ごとに順番に取得する
        for subject in try await source.subjectsNeedingAnswer(org: org) {
            let threads = try await source.questionThreads(of: subject)
            questions += InboxQuestion.unanswered(in: threads, of: subject, trustedAuthors: trustedAuthors)
        }
        return questions.sorted { ($0.comment.createdAt, $0.id) < ($1.comment.createdAt, $1.id) }
    }

    /// 「急がない」に出す Issue を、更新の新しい順に返す。
    /// 信用する author が作ったものだけを扱う（public リポジトリでは誰でも Issue を作れ、ラベルの付いた Issue を装えるため）
    public func lowPriorityIssues(org: String) async throws -> [InboxIssue] {
        try await source.lowPriorityIssues(org: org)
            .filter { trustedAuthors.contains($0.author) }
            .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }
}
