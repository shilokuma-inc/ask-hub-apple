import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 状態リポジトリの中身を、対象のリポジトリの Discussion に写す（`docs/renewal/flows.md` の「Discussion の写し」）。
///
/// 常駐のループの周の最後に、epic ごとに写しの一式（`DiscussionCopies`）を作り、前に写し終えたときから変わっていれば、
/// Discussion と照らし合わせて、無いものを作り、違うものを直す。
/// - 写しは表示と照らし合わせのためだけのもの。正本は状態リポジトリで、Discussion のコメントは指示として読まない
/// - やり直しても重ならない: 作る前に、状態に戻した id（`EpicFile.discussion`・`Question.comment`・`GoalFile.comment`）を見て、
///   無ければ自分が書いた（`viewerDidAuthor`）目印で探す。状態に戻した id の写しが一覧に無ければ、消されたか確かめ、消されていなければ何も作らない
/// - 失敗しても、依頼から開始までの流れを止めない。失敗の区分（`FailurePolicy`）に沿って epic ごとに間を空け、後の周でやり直す
public actor DiscussionMirror {
    public struct Settings: Sendable {
        /// Discussion を作るカテゴリ（Discussions を有効にすると GitHub が作る既定のカテゴリ。今の仕組みと同じ）
        public var category = "Ideas"
        /// 1 周で GitHub と照らし合わせる epic の数（周を長引かせない。残りは次の周）
        public var maxSyncsPerCycle = 5
        /// やめた・マージした epic を照らし合わせ続ける期間（最後の段階を写すため）
        public var endedEpicWindow: Duration = .seconds(24 * 60 * 60)
        /// 人の対応が要る失敗（Discussions が無効・権限が無いなど）の後に、もう一度試すまでの間
        public var manualWait: Duration = .seconds(60 * 60)
        /// 作った Discussion を目印で探すときに、epic を作った時刻より前に遡る幅（時計のずれ）
        public var clockSkew: Duration = .seconds(10 * 60)

        public init() {}
    }

    nonisolated let context: CommanderContext
    nonisolated let api: any DiscussionAPI
    nonisolated let settings: Settings
    nonisolated let policy: FailurePolicy
    nonisolated let log: @Sendable (String) -> Void

    /// epic ごとの、最後に写し終えた写しの一式のハッシュ
    private var synced: [ULID: String] = [:]
    /// epic ごとの失敗
    private var failures: [ULID: Backoff] = [:]
    /// Discussion を作れると分かったリポジトリの id とカテゴリ
    private var repositories: [RepositoryFullName: DiscussionRepository] = [:]
    /// 読み直して署名を確かめた依頼（変わらないので覚えておく）
    private var requests: [ULID: RequestIntent] = [:]

    struct Backoff {
        /// これまでの失敗の区分（古い順）
        var classes: [FailureClass]
        /// 次に試してよい時刻
        var retryAt: Date
    }

    public init(
        context: CommanderContext,
        api: any DiscussionAPI,
        settings: Settings = Settings(),
        policy: FailurePolicy = FailurePolicy(),
        log: @escaping @Sendable (String) -> Void
    ) {
        self.context = context
        self.api = api
        self.settings = settings
        self.policy = policy
        self.log = log
    }

    /// 写しを照らし合わせる。失敗しても投げない（ログに書き、後の周でやり直す）
    public func syncAll(verifier: IntentVerifier) async {
        let epics: [EpicFile]
        do {
            epics = try await targets()
        } catch {
            log("写しの対象の epic を読めない（\(error)）。次の周でやり直す")
            return
        }
        var remaining = settings.maxSyncsPerCycle
        for epic in epics where remaining > 0 {
            if let backoff = failures[epic.id], context.now() < backoff.retryAt { continue }
            do {
                if try await sync(epic, verifier: verifier) { remaining -= 1 }
                failures[epic.id] = nil
            } catch {
                remaining -= 1
                // 止めた・アカウント全体の上限や認証の失敗は、ほかの epic も同じなので、この周はやめる
                guard record(error, for: epic) else { return }
            }
        }
    }

    /// 写す epic: 終わっていない epic と、終わってから間もない epic
    private func targets() async throws(CommanderError) -> [EpicFile] {
        let now = context.now()
        let window = TimeInterval(settings.endedEpicWindow.components.seconds)
        var epics: [EpicFile] = []
        for repo in try await context.repositories() {
            epics += try await context.epics(of: repo) { epic in
                ![.merged, .abandoned].contains(epic.stage) || now.timeIntervalSince(epic.updatedAt.date) < window
            }
        }
        return epics
    }

    /// 1 つの epic の写しを照らし合わせる。GitHub を読み書きしたら true（前に写し終えたときから変わっていなければ false）
    func sync(_ epic: EpicFile, verifier: IntentVerifier) async throws(MirrorError) -> Bool {
        let state = try await stateOf(epic)
        let request = try await request(of: epic, verifier: verifier)
        let copies = DiscussionCopies(
            epic: epic, request: request, questions: state.questions, goal: state.goal, readiness: state.readiness
        )
        let fingerprint = copies.fingerprint
        guard synced[epic.id] != fingerprint else { return false }
        let thread = try await thread(of: epic, copies: copies)
        try await reconcile(thread, with: copies, epic: epic, state: state)
        synced[epic.id] = fingerprint
        return true
    }

    /// 元の依頼。読めない・署名が合わないときは nil（本文を写さない）
    private func request(of epic: EpicFile, verifier: IntentVerifier) async throws(MirrorError) -> RequestIntent? {
        if let request = requests[epic.id] { return request }
        let envelope = try await Self.state { () throws(CommanderError) in try await context.envelope(of: epic.origin, verifier: verifier) }
        guard let request = envelope.flatMap({ try? RequestIntent(envelope: $0) }) else { return nil }
        requests[epic.id] = request
        return request
    }

    /// 失敗を記録し、次に試す時刻を決める。この周の写しを続けてよければ true
    private func record(_ error: MirrorError, for epic: EpicFile) -> Bool {
        let now = context.now()
        let failure = error.attemptFailure(now: now)
        let earlier = failures[epic.id]?.classes ?? []
        var retryAt: Date
        switch policy.decide(failure.failureClass, retryAt: failure.retryAt, earlier: earlier, now: now) {
        case let .retry(at):
            // 上限の解除の時刻が分かれば、それより前には試さない
            retryAt = max(at.date, failure.retryAt?.date ?? at.date)
        case .pause:
            log("司令塔を止めたので、Discussion の写しを中断した")
            return false
        case .human, .fix:
            retryAt = now.addingTimeInterval(TimeInterval(settings.manualWait.components.seconds))
        }
        failures[epic.id] = Backoff(classes: earlier + [failure.failureClass], retryAt: retryAt)
        let kind = failure.failureClass.rawValue
        log("epic \(epic.id)（\(epic.repo)）の Discussion の写しを書けない（\(kind)）: \(failure.message)。\(Timestamp(retryAt)) より後にやり直す")
        return ![.githubOutage, .authExpired].contains(failure.failureClass)
    }

    /// Discussion を作れると分かったリポジトリの設定。作れなければ `unavailable`
    func usableRepository(_ repo: RepositoryFullName) async throws(MirrorError) -> (DiscussionRepository, DiscussionRepository.Category) {
        let repository: DiscussionRepository
        if let known = repositories[repo] {
            repository = known
        } else {
            repository = try await Self.github { () throws(DiscussionError) in try await api.repository(repo) }
        }
        guard repository.discussionsEnabled else {
            throw .github(.unavailable("\(repo) の Discussions が無効。リポジトリの Settings → General → Features で有効にする（写しはそれまで書かない）"))
        }
        guard let category = repository.categories.first(where: { $0.name == settings.category }) else {
            throw .github(.unavailable("\(repo) の Discussions にカテゴリ「\(settings.category)」が無い。GitHub で作る（写しはそれまで書かない）"))
        }
        repositories[repo] = repository
        return (repository, category)
    }

    /// 覚えたリポジトリの設定を捨てる（カテゴリが消されたなどで作れなかったとき）
    func forgetRepository(_ repo: RepositoryFullName) {
        repositories[repo] = nil
    }
}

/// 写しを照らし合わせられなかった理由
enum MirrorError: Error, Equatable {
    /// 状態リポジトリを読み書きできない
    case state(CommanderError)
    case github(DiscussionError)
    /// Discussion が状態と合わない（消された・一覧が欠けた）。`failure` に区分と説明を入れる
    case inconsistent(AttemptFailure)

    func attemptFailure(now: Date) -> AttemptFailure {
        switch self {
        case let .state(error): error.attemptFailure(now: now)
        case let .github(error): error.attemptFailure(now: now)
        case let .inconsistent(failure): failure
        }
    }
}
