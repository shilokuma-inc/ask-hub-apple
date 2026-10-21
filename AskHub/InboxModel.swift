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

    /// 未回答の質問（作成日時の古い順）。一覧に出す順は `groupedQuestions`
    private(set) var questions: [InboxQuestion] = []
    /// アプリから回答した質問。GitHub の検索に回答が反映されるまで、取り直しても一覧に出さない
    private var answeredQuestionIDs: Set<String> = []
    /// 直前の取得・投稿に使ったトークンの SHA-256。変わったら（別のアカウントになりうるので）回答済みの記録を捨てる。
    /// トークンの値そのものはモデルに残さない
    private var lastTokenFingerprint: String?
    private(set) var issues: [InboxIssue] = []
    /// アプリから閉じた実機確認の Issue。GitHub の検索に反映されるまで、取り直しても一覧に出さない
    private var closedIssueIDs: Set<String> = []
    private(set) var state = LoadState.idle
    /// 直前に取得を始めた時刻。自動更新（`refreshIfStale`）の間隔の判断に使う
    private(set) var lastRefreshed: Date?

    /// 回答の添付（`InboxModel+Attachments.swift`）も同じトークンで上げる
    let tokenStore: any TokenStore
    private let makeSource: @Sendable (String) -> any InboxSource
    private let makePoster: @Sendable (String) -> any AnswerPosting
    private let makeStarter: @Sendable (String) -> any LoopStarting
    private let makeCloser: @Sendable (String) -> any IssueClosing
    private let makeApprover: @Sendable (String) -> any DecisionApproving
    private let makeInstructionPoster: @Sendable (String) -> any DecisionInstructionPosting
    /// リポジトリごとの信用する author（トークンごと）
    private let makeTrust: @Sendable (String) -> any TrustedAuthorsResolving
    /// 仮決め一覧のコメントの取得元（トークンごと）
    private let makeCommentsFetcher: @Sendable (String) -> any DecisionLogCommentsFetching
    /// 回答の添付を上げる先（トークンごと）
    let makeUploader: @Sendable (String) -> any AttachmentUploading
    /// 直前の取得で求めた、リポジトリごとの信用する author（画面での判定に使う。キーは `owner/repo` の小文字）
    private var trustedAuthorsByRepository: [String: TrustedAuthors] = [:]
    /// 一覧を取得する organization。取得のたびに読む（設定で変えたら次の取得から反映する）
    private let organizations: () -> [String]

    init(
        tokenStore: any TokenStore = KeychainTokenStore.gitHub,
        makeSource: @escaping @Sendable (String) -> any InboxSource = { GitHubInboxSource(client: GitHubClient(token: $0)) },
        makePoster: @escaping @Sendable (String) -> any AnswerPosting = { GitHubAnswerPoster(client: GitHubClient(token: $0)) },
        makeStarter: @escaping @Sendable (String) -> any LoopStarting = { GitHubLoopStarter(client: GitHubClient(token: $0)) },
        makeCloser: @escaping @Sendable (String) -> any IssueClosing = { GitHubIssueCloser(client: GitHubClient(token: $0)) },
        makeApprover: @escaping @Sendable (String) -> any DecisionApproving = { GitHubDecisionApprover(client: GitHubClient(token: $0)) },
        makeInstructionPoster: @escaping @Sendable (String) -> any DecisionInstructionPosting = {
            GitHubDecisionInstructionPoster(client: GitHubClient(token: $0))
        },
        organizations: @escaping () -> [String] = { OrganizationSettings.load() },
        makeTrust: @escaping @Sendable (String) -> any TrustedAuthorsResolving = { RepositoryTrustCache.trust(token: $0) },
        makeCommentsFetcher: @escaping @Sendable (String) -> any DecisionLogCommentsFetching = {
            GitHubDecisionLogComments(client: GitHubClient(token: $0))
        },
        makeUploader: @escaping @Sendable (String) -> any AttachmentUploading = {
            GitHubAttachmentUploader(client: GitHubClient(token: $0))
        }
    ) {
        self.makeCommentsFetcher = makeCommentsFetcher
        self.makeUploader = makeUploader
        self.tokenStore = tokenStore
        self.makeTrust = makeTrust
        self.organizations = organizations
        self.makeSource = makeSource
        self.makePoster = makePoster
        self.makeStarter = makeStarter
        self.makeCloser = makeCloser
        self.makeApprover = makeApprover
        self.makeInstructionPoster = makeInstructionPoster
    }

    /// 回答を投稿するときのトークンが無い
    struct MissingTokenError: Error {}

    /// 要回答の一覧に出す順。同じ Discussion の質問を続けて並べ（Discussion #418 の Q1）、PR の ask はそれぞれの作成日時の位置に置く（仮決め #421）
    var groupedQuestions: [InboxQuestion] {
        InboxQuestion.groupedByDiscussion(questions)
    }

    /// 同じ Discussion / PR に残っている、ほかの未回答の質問の数
    func remainingQuestions(besides question: InboxQuestion) -> Int {
        questions.filter { $0.subject.nodeID == question.subject.nodeID && $0.id != question.id }.count
    }

    /// Discussion / PR を作ったのが信用する author か。信用外の author の Discussion に付いた `manual-loop` はオーケストレーターが無視する
    func isTrustedAuthor(of subject: InboxSubject) -> Bool {
        (trustedAuthorsByRepository[subject.repository.lowercased()] ?? .default).contains(subject.author)
    }

    /// 仮決め一覧の指示とループの返信の履歴。コメントはページングを最後まで追って古い順に読み、
    /// 処理済みかはオーケストレーターと同じ規則（`DecisionLogHistory`）で、そのリポジトリの信用する author をもとに判定する
    func decisionHistory(for issue: InboxIssue) async throws -> DecisionLogHistory {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        async let comments = makeCommentsFetcher(token).comments(of: issue)
        async let trusted = makeTrust(token).trustedAuthors(for: issue.repository)
        return try await DecisionLogHistory(comments: comments, trustedAuthors: trusted)
    }

    /// Discussion の回答を確定し、ループを始めてよい印（`ready-for-loop`）を付ける（Discussion #1 の Q3）。
    /// 手で回すなら、代わりに `manual-loop` を付ける（Discussion #273 の Q2）
    /// 手で回すときは、`assignee` を担当者として Discussion に知らせる（@メンション付きのコメント）
    /// オーケストレーターで始めるときは、`options` が既定でなければ、`ready-for-loop` より先にモデルとエフォートのコメントを付ける
    /// （起動スクリプトが準備のときに読むので、ラベルより後だと間に合わないことがある）
    func startLoop(
        for discussion: InboxSubject,
        runner: LoopRunner = .orchestrator,
        assignee: String? = nil,
        options: LoopOptions = LoopOptions()
    ) async throws {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        let starter = makeStarter(token)
        switch runner {
        case .orchestrator:
            if !options.isDefault {
                try await starter.setLoopOptions(options, on: discussion)
            }
            try await starter.markReadyForLoop(discussion)

        case .manual:
            try await starter.markManualLoop(discussion)
            if let assignee {
                try await starter.assignManualLoop(discussion, to: assignee)
            }
        }
    }

    /// 手動ループの担当者に選べるアカウント（そのリポジトリに書き込み権限を持つ人）と、自分の login。
    /// 候補を取れなかったときは、自分だけを返す
    func assigneeChoices(in repository: String) async -> (candidates: [String], viewer: String?) {
        guard let token = try? tokenStore.load() else {
            return ([], nil)
        }
        let starter = makeStarter(token)
        let viewer = try? await starter.viewerLogin()
        let candidates = (try? await starter.assigneeCandidates(in: repository)) ?? []
        guard let viewer else {
            return (candidates, nil)
        }
        return (candidates.contains { $0.caseInsensitiveCompare(viewer) == .orderedSame } ? candidates : [viewer] + candidates, viewer)
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

    /// 実機確認の Issue を確認済み（完了）として閉じる（Discussion #331 の Q5）。成功したらその Issue を一覧から外し、一覧を取り直す。
    /// 取り直しは待たずに返す（一覧からは外し終えているので、詳細画面をすぐ閉じられるようにする）
    func closeAsVerified(_ issue: InboxIssue) async throws {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        useToken(token)
        try await makeCloser(token).closeAsVerified(issue)
        // 閉じるのを待つ間に別のトークンで取り直した場合は、新しいトークンの一覧と記録に手を付けない
        guard Self.fingerprint(of: token) == lastTokenFingerprint else {
            return
        }
        // 検索の反映を待たずに、閉じた Issue はすぐ一覧から消す。取り直しても戻さない
        closedIssueIDs.insert(issue.id)
        issues.removeAll { $0.id == issue.id }
        Task { await refresh() }
    }

    /// 仮決め一覧の 1 項目を承認する（本文のチェックを付ける。Discussion #349 の Q2）。
    /// 承認器が読み直した本文を一覧の Issue にも反映し、詳細画面を開き直しても古い本文に戻らないようにする
    func approve(_ item: DecisionLogItem, in issue: InboxIssue) async throws -> DecisionApproval {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        useToken(token)
        let result = try await makeApprover(token).approve(item.text, in: issue)
        guard Self.fingerprint(of: token) == lastTokenFingerprint else {
            return result
        }
        let body = switch result {
        case let .approved(body), let .alreadyApproved(body), let .notFound(body):
            body
        }
        if let index = issues.firstIndex(where: { $0.id == issue.id }) {
            issues[index].body = body
        }
        return result
    }

    /// 仮決めの 1 項目への指示（別案・自由記述）を 1 件のコメントとして投稿し、コメントの URL を返す（Discussion #349 の Q3）
    func post(_ instruction: DecisionInstruction, for item: DecisionLogItem, to issue: InboxIssue) async throws -> URL {
        guard let token = try tokenStore.load() else {
            throw MissingTokenError()
        }
        useToken(token)
        return try await makeInstructionPoster(token).post(instruction, for: item, to: issue)
    }

    /// トークンが変わったら（別のアカウントになりうるので）回答済み・閉じた記録を捨てる
    private func useToken(_ token: String) {
        let fingerprint = Self.fingerprint(of: token)
        if fingerprint != lastTokenFingerprint {
            answeredQuestionIDs.removeAll()
            closedIssueIDs.removeAll()
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
        } while needsRefreshAfterLoading && !Task.isCancelled
    }

    /// 自動更新（フォアグラウンド復帰・Background App Refresh）。取得中か、直前の取得から間もなければ取り直さない
    func refreshIfStale(now: Date = .now) async {
        guard !isLoading, AutoRefresh.isStale(lastRefreshed: lastRefreshed, now: now) else {
            return
        }
        await refresh()
    }

    private func load() async {
        let token: String
        do {
            guard let saved = try tokenStore.load() else {
                questions = []
                issues = []
                state = .needsToken
                return
            }
            token = saved
        } catch {
            state = .failed("Keychain からトークンを読み込めませんでした")
            return
        }

        useToken(token)
        let previous = (state: state, lastRefreshed: lastRefreshed)
        state = .loading
        lastRefreshed = .now
        let fetcher = InboxFetcher(source: makeSource(token), trustedAuthors: makeTrust(token))
        let orgs = organizations()
        do {
            async let questions = fetcher.unansweredQuestions(orgs: orgs)
            async let issues = fetcher.lowPriorityIssues(orgs: orgs)
            let (fetchedQuestions, fetchedIssues) = try await (questions, issues)
            // 取得を待つ間に別のトークンで回答した場合は、古いトークンでの結果を捨てて取り直す
            guard Self.fingerprint(of: token) == lastTokenFingerprint else {
                needsRefreshAfterLoading = true
                state = .idle
                return
            }
            // 取得結果に出てこなくなった（検索に回答が反映された）質問は、覚えておく必要がない
            answeredQuestionIDs.formIntersection(fetchedQuestions.map(\.id))
            self.questions = fetchedQuestions.filter { !answeredQuestionIDs.contains($0.id) }
            closedIssueIDs.formIntersection(fetchedIssues.map(\.id))
            self.issues = fetchedIssues.filter { !closedIssueIDs.contains($0.id) }
            // 手で回す印を付けてよいかの判定（Discussion の author）に使う。取得は書き込み権限の結果を使い回すので、追加の問い合わせは少ない
            var trusted: [String: TrustedAuthors] = [:]
            for repository in Set(fetchedQuestions.map { $0.subject.repository.lowercased() }) {
                trusted[repository] = await fetcher.trustedAuthors(for: repository)
            }
            trustedAuthorsByRepository = trusted
            state = .loaded
        } catch {
            // バックグラウンドの取得が打ち切られた。失敗とは表示せず、次の自動更新で取り直せるようにする
            if Task.isCancelled {
                (state, lastRefreshed) = previous
                return
            }
            state = .failed(Self.message(for: error))
        }
    }

    /// 実機確認の Issue を閉じられなかったときの説明。トークンの値は含めない
    static func closeMessage(for error: any Error) -> String {
        switch error {
        // Issues の書き込み権限が無いと 403、リポジトリが見えないトークンでは 404 になる
        case GitHubError.http(status: 403, _), GitHubError.http(status: 404, _):
            "閉じられませんでした。トークンに、このリポジトリの Issues の書き込み権限（Read and write）があるか確かめてください"

        default:
            message(for: error)
        }
    }

    /// 仮決めの承認・指示を送れなかったときの説明。トークンの値は含めない
    static func decisionMessage(for error: any Error) -> String {
        switch error {
        // Issues の書き込み権限が無いと 403、リポジトリが見えないトークンでは 404 になる
        case GitHubError.http(status: 403, _), GitHubError.http(status: 404, _):
            "送れませんでした。トークンに、このリポジトリの Issues の書き込み権限（Read and write）があるか確かめてください"

        case DecisionInstructionError.invalidInstruction:
            "別案を選ぶか、補足を入力してください"

        case DecisionInstructionError.notDecisionLog, DecisionApprovalError.notDecisionLog:
            "仮決め一覧ではない Issue には送れません"

        default:
            message(for: error)
        }
    }

    /// 仮決め一覧の履歴を読めなかったときの説明。トークンの値は含めない
    static func historyMessage(for error: any Error) -> String {
        switch error {
        // リポジトリが見えないトークンでは 404、権限が足りなければ 403 になる
        case GitHubError.http(status: 403, _), GitHubError.http(status: 404, _):
            "履歴を読めませんでした。トークンに、このリポジトリの Issues の読み取り権限があるか確かめてください"

        default:
            message(for: error)
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
