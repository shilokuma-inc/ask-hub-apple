/// 受信箱の取得元。テストでは差し替える
public protocol InboxSource: Sendable {
    /// `needs-answer` が付いた open な Discussion と PR
    func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject]
    /// Discussion / PR の、質問かもしれないスレッドの一覧
    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread]
}

/// 受信箱の「要回答」に出す未回答の質問を集める
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
}
