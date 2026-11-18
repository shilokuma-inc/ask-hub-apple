import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// やめた epic の PR を閉じるのに使う、対象のリポジトリの GitHub の操作（本物は `GitHubPullRequestClosing`。テストでは差し替える）
public protocol PullRequestClosing: Sendable {
    /// 同じリポジトリのブランチからの開いた PR。`head` を渡せばそのブランチからの PR、`base` を渡せばその向き先の PR に絞る
    func openPullRequests(_ repo: RepositoryFullName, head: String?, base: String?) async throws(PullRequestError) -> [PullRequest]
    func close(_ repo: RepositoryFullName, number: Int) async throws(PullRequestError)
    func comment(_ repo: RepositoryFullName, number: Int, body: String) async throws(PullRequestError)
}

/// 持ち主ごとのトークンで、`GitHubPullRequests` を使って PR を閉じる
public struct GitHubPullRequestClosing: PullRequestClosing {
    public var transport: any HTTPTransport
    public var token: @Sendable (_ owner: String) async throws -> String

    public init(
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        token: @escaping @Sendable (_ owner: String) async throws -> String
    ) {
        self.transport = transport
        self.token = token
    }

    private func github(_ repo: RepositoryFullName) -> GitHubPullRequests {
        GitHubPullRequests(repository: repo, transport: transport, token: token)
    }

    public func openPullRequests(
        _ repo: RepositoryFullName,
        head: String?,
        base: String?
    ) async throws(PullRequestError) -> [PullRequest] {
        try await github(repo).openPullRequests(head: head, base: base)
    }

    public func close(_ repo: RepositoryFullName, number: Int) async throws(PullRequestError) {
        try await github(repo).setState(number: number, to: .closed)
    }

    public func comment(_ repo: RepositoryFullName, number: Int, body: String) async throws(PullRequestError) {
        try await github(repo).comment(number: number, body: body)
    }
}

/// 開始した後にやめた epic の、開いている子 PR と最終 PR を閉じる（`docs/renewal/flows.md` の「開始した後の取り下げ」）。
///
/// 常駐のループの周の最後に、やめた epic のうち開始していた（`mac` のある）ものを見て、作業ブランチ（`askhub/<epic の id>`）宛ての子 PR と、
/// 作業ブランチからの最終 PR のうち、開いているものを閉じてから、取り下げたことのコメントを書く。
/// - マージしない。作業ブランチと子ブランチは消さない（後から取り出せる）
/// - 同じリポジトリのブランチからの PR だけを閉じる（フォークからの PR には触れない）
/// - やめたときに動いていたジョブ（実装・最終 PR の作成）は、終わるまでに PR を作ることがあるので、やめてから `window` の間は
///   `recheckInterval` ごとに見直す
/// - 閉じた後にコメントを書けなかった PR は、次に見るときにコメントだけを書き直す（閉じた PR は一覧に出ないので、覚えておく）
/// - 失敗しても周は止めない。`retryInterval` の後にやり直す。GitHub の上限なら、解けるまでどの epic も見ない
public actor AbandonedPullRequests {
    public struct Settings: Sendable {
        /// やめてから見続ける期間
        public var window: Duration = .seconds(24 * 60 * 60)
        /// 見直す間隔（やめたときに動いていたジョブが作った PR を閉じる）
        public var recheckInterval: Duration = .seconds(30 * 60)
        /// 失敗した後に、もう一度試すまでの間
        public var retryInterval: Duration = .seconds(5 * 60)

        public init() {}
    }

    nonisolated let context: CommanderContext
    nonisolated let github: any PullRequestClosing
    nonisolated let settings: Settings
    nonisolated let log: @Sendable (String) -> Void

    /// epic ごとの、次に見る時刻
    private var nextCheck: [ULID: Date] = [:]
    /// 閉じたが、取り下げのコメントをまだ書けていない PR（epic ごと）
    private(set) var uncommented: [ULID: Set<Int>] = [:]
    /// GitHub の上限が解ける時刻。それまでは見ない
    private var pausedUntil: Date?

    public init(
        context: CommanderContext,
        github: any PullRequestClosing,
        settings: Settings = Settings(),
        log: @escaping @Sendable (String) -> Void
    ) {
        self.context = context
        self.github = github
        self.settings = settings
        self.log = log
    }

    /// やめた epic の開いている PR を閉じる。失敗しても投げない（ログに書き、後の周でやり直す）
    public func closeAll() async {
        let now = context.now()
        if let pausedUntil, now < pausedUntil { return }
        let epics: [EpicFile]
        do {
            epics = try await targets(in: try await context.snapshot())
        } catch {
            log("やめた epic を読めないので、開いている PR を閉じるのは次の周でやり直す（\(error)）")
            return
        }
        let ids = Set(epics.map(\.id))
        nextCheck = nextCheck.filter { ids.contains($0.key) }
        uncommented = uncommented.filter { ids.contains($0.key) }
        for epic in epics {
            if let next = nextCheck[epic.id], now < next { continue }
            do {
                let closed = try await close(epic)
                nextCheck[epic.id] = now.addingTimeInterval(Self.seconds(settings.recheckInterval))
                if !closed.isEmpty {
                    let numbers = closed.map { "#\($0)" }.joined(separator: "・")
                    log("やめた epic \(epic.id)（\(epic.repo)）の開いている PR \(numbers) を、取り下げたことのコメントを付けて閉じた")
                }
            } catch {
                log("やめた epic \(epic.id)（\(epic.repo)）の開いている PR を閉じられない（\(error)）。後でやり直す")
                guard case let .rateLimited(retryAfter) = error else {
                    nextCheck[epic.id] = now.addingTimeInterval(Self.seconds(settings.retryInterval))
                    continue
                }
                pausedUntil = now.addingTimeInterval(Self.seconds(max(retryAfter, settings.retryInterval)))
                return
            }
        }
    }

    /// 見る epic: やめてから `window` の間の、開始していた epic
    private func targets(in reader: CommanderContext) async throws(CommanderError) -> [EpicFile] {
        let now = context.now()
        let window = Self.seconds(settings.window)
        var epics: [EpicFile] = []
        for repo in try await reader.repositories() {
            epics += try await reader.epics(of: repo) { epic in
                epic.stage == .abandoned && epic.mac != nil && now.timeIntervalSince(epic.updatedAt.date) < window
            }
        }
        return epics
    }

    /// epic の開いている子 PR と最終 PR を閉じ、取り下げたことのコメントを書く。閉じた PR の番号を返す
    func close(_ epic: EpicFile) async throws(PullRequestError) -> [Int] {
        for number in (uncommented[epic.id] ?? []).sorted() {
            try await github.comment(epic.repo, number: number, body: Self.comment(for: epic))
            uncommented[epic.id]?.remove(number)
        }
        let branch = epic.branch ?? PrepareWorkspaceRunner.branch(of: epic.id)
        let children = try await github.openPullRequests(epic.repo, head: nil, base: branch)
        let finals = try await github.openPullRequests(epic.repo, head: branch, base: nil)
        var closed: [Int] = []
        for pull in children + finals where !closed.contains(pull.number) {
            // 閉じてからコメントを書く（先にコメントを書くと、閉じられずにやり直したときにコメントが重なる）
            try await github.close(epic.repo, number: pull.number)
            closed.append(pull.number)
            uncommented[epic.id, default: []].insert(pull.number)
            try await github.comment(epic.repo, number: pull.number, body: Self.comment(for: epic))
            uncommented[epic.id]?.remove(pull.number)
        }
        return closed
    }

    /// 閉じた PR に書くコメント。最後の行に目印（`{"type":"abandoned","epic":"…"}`）を置く（書くだけで読まない）
    static func comment(for epic: EpicFile) -> String {
        let request = epic.discussion.map { "（依頼: #\($0)）" } ?? ""
        let body = "AskHub で、この PR の元の依頼\(request)を取り下げたので、マージせずに閉じました。ブランチは消さずに残しています。"
        return ProtocolMarker.text(body: body, marker: .object(["type": .string("abandoned"), "epic": .string(epic.id.rawValue)]))
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
    }
}
