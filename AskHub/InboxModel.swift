import AskHubKit
import CryptoKit
import Foundation
import Observation

/// 受信箱の一覧（要回答 / 急がない）の状態
@MainActor
@Observable
final class InboxModel {
    enum LoadState: Equatable {
        /// まだ取得していない
        case idle
        case loading
        case loaded
        /// トークンが保存されていない
        case needsToken
        /// 直前の取得に失敗した。一覧は前回の結果を残す
        case failed(String)
    }

    /// 対象の organization（Discussion #1 の Q6）
    static let org = "shilokuma-inc"

    private(set) var questions: [InboxQuestion] = []
    /// アプリから回答した質問。GitHub の検索に回答が反映されるまで、取り直しても一覧に出さない
    private var answeredQuestionIDs: Set<String> = []
    /// 直前の取得・投稿に使ったトークンの SHA-256。変わったら（別のアカウントになりうるので）回答済みの記録を捨てる。
    /// トークンの値そのものはモデルに残さない
    private var lastTokenFingerprint: String?
    private(set) var issues: [InboxIssue] = []
    /// `ready-for-loop` を付けて、ループの開始を待っている Discussion
    private(set) var waiting: [WaitingDiscussion] = []
    private(set) var state = LoadState.idle

    private let tokenStore: any TokenStore
    private let makeSource: @Sendable (String) -> any InboxSource
    private let makePoster: @Sendable (String) -> any AnswerPosting
    private let makeStarter: @Sendable (String) -> any LoopStarting
    private let trustedAuthors: TrustedAuthors

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        trustedAuthors: TrustedAuthors = .default,
        makeSource: @escaping @Sendable (String) -> any InboxSource = { GitHubInboxSource(client: GitHubClient(token: $0)) },
        makePoster: @escaping @Sendable (String) -> any AnswerPosting = { GitHubAnswerPoster(client: GitHubClient(token: $0)) },
        makeStarter: @escaping @Sendable (String) -> any LoopStarting = { GitHubLoopStarter(client: GitHubClient(token: $0)) }
    ) {
        self.tokenStore = tokenStore
        self.trustedAuthors = trustedAuthors
        self.makeSource = makeSource
        self.makePoster = makePoster
        self.makeStarter = makeStarter
    }

    /// 回答を投稿するときのトークンが無い
    struct MissingTokenError: Error {}

    /// 同じ Discussion / PR に残っている、ほかの未回答の質問の数
    func remainingQuestions(besides question: InboxQuestion) -> Int {
        questions.filter { $0.subject.nodeID == question.subject.nodeID && $0.id != question.id }.count
    }

    /// Discussion の回答を確定し、ループを始めてよい印（`ready-for-loop`）を付ける（Discussion #1 の Q3）
    func startLoop(for discussion: InboxSubject) async throws {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        try await makeStarter(token).markReadyForLoop(discussion)
    }

    /// 質問に回答を投稿する。成功したらその質問を一覧から外し、一覧を取り直す
    func post(_ answer: Answer, to question: InboxQuestion) async throws {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        _ = try await makePoster(token).post(answer, to: question)
        // 検索の反映を待たずに、回答した質問はすぐ一覧から消す。取り直しても戻さない
        useToken(token)
        answeredQuestionIDs.insert(question.id)
        questions.removeAll { $0.id == question.id }
        await refresh()
    }

    /// トークンが変わったら（別のアカウントになりうるので）回答済みの記録を捨てる
    private func useToken(_ token: String) {
        let fingerprint = Self.fingerprint(of: token)
        if fingerprint != lastTokenFingerprint {
            answeredQuestionIDs.removeAll()
            lastTokenFingerprint = fingerprint
        }
    }

    /// トークンを比べるための SHA-256（16 進）
    private static func fingerprint(of token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isLoading: Bool {
        state == .loading
    }

    /// 取得中に `refresh()` が呼ばれたか。取得が終わったら最新のトークンで取り直す
    private var needsRefreshAfterLoading = false

    /// 保存済みのトークンで、要回答と急がないをまとめて取得し直す。
    /// 取得中に呼ばれた場合は、その取得が終わってから取り直す（設定でトークンを変えた直後など）
    func refresh() async {
        guard !isLoading else {
            needsRefreshAfterLoading = true
            return
        }
        repeat {
            needsRefreshAfterLoading = false
            await load()
        } while needsRefreshAfterLoading
    }

    private func load() async {
        let token: String
        do {
            guard let saved = try tokenStore.load() else {
                questions = []
                issues = []
                waiting = []
                state = .needsToken
                return
            }
            token = saved
        } catch {
            state = .failed("Keychain からトークンを読み込めませんでした")
            return
        }

        useToken(token)
        state = .loading
        let fetcher = InboxFetcher(source: makeSource(token), trustedAuthors: trustedAuthors)
        do {
            async let questions = fetcher.unansweredQuestions(org: Self.org)
            async let issues = fetcher.lowPriorityIssues(org: Self.org)
            async let waiting = fetcher.waitingDiscussions(org: Self.org)
            let (fetchedQuestions, fetchedIssues, fetchedWaiting) = try await (questions, issues, waiting)
            // 取得を待つ間に別のトークンで回答した場合は、古いトークンでの結果を捨てて取り直す
            guard Self.fingerprint(of: token) == lastTokenFingerprint else {
                needsRefreshAfterLoading = true
                state = .idle
                return
            }
            // 取得結果に出てこなくなった（検索に回答が反映された）質問は、覚えておく必要がない
            answeredQuestionIDs.formIntersection(fetchedQuestions.map(\.id))
            self.questions = fetchedQuestions.filter { !answeredQuestionIDs.contains($0.id) }
            self.issues = fetchedIssues
            self.waiting = fetchedWaiting
            state = .loaded
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// 取得・投稿の失敗の説明。トークンの値は含めない
    static func message(for error: any Error) -> String {
        if error is MissingTokenError {
            return "トークンが未設定です。設定で保存してください"
        }
        if let error = error as? AnswerPostingError {
            switch error {
            case .invalidAnswer:
                return "選択肢を選ぶか、回答を入力してください"

            case .missingCommentID:
                return "返信先のコメントを特定できませんでした。GitHub で回答してください"
            }
        }
        if error is KeychainError {
            return "Keychain からトークンを読み込めませんでした"
        }
        return switch error as? GitHubError {
        case .http(status: 401, _):
            "トークンが無効です。設定でトークンを保存し直してください"

        case let .http(status, message):
            "GitHub とのやり取りに失敗しました（HTTP \(status)\(message.map { ": \($0)" } ?? "")）"

        case let .rateLimited(retryAfter):
            "GitHub のレート制限中です。\(retryAfter.components.seconds) 秒ほど待ってから更新してください"

        case .graphQL, .invalidResponse:
            "GitHub の応答を読み取れませんでした"

        case nil:
            "GitHub とのやり取りに失敗しました（\(error.localizedDescription)）"
        }
    }
}
