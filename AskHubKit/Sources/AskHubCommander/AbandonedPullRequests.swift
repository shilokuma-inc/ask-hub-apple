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
/// - 最終 PR は、作業ブランチから base（`repo.json` の `build.baseBranch`）への PR だけを閉じる
/// - 閉じた後にコメントを書けなかった PR は、次に見るときにコメントだけを書き直す（閉じた PR は一覧に出ないので、覚えておく。見る期間を過ぎても書き直す）。
///   覚えるのはメモリの中だけなので、その間に司令塔を再起動すると、閉じた PR にコメントは書かれない
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

    /// 見る epic と、最終 PR の向き先（`repo.json` の `build.baseBranch`。「このリリースを直す」epic は `release/<版>`。読めなければ nil で、向き先で絞らない）
    struct Target {
        var epic: EpicFile
        var base: String?
        /// 開いている PR を探すか（見る期間を過ぎて、書き直すコメントだけが残った epic は探さない）
        var searches: Bool
    }

    /// 1 つの epic を見た結果
    struct Pass {
        var closed: [Int] = []
        /// コメントを書けなかった PR と、そのわけ（次に見るときに書き直す）
        var commentFailures: [Int: PullRequestError] = [:]
    }

    /// やめた epic の開いている PR を閉じる。失敗しても投げない（ログに書き、後の周でやり直す）
    public func closeAll() async {
        let now = context.now()
        if let pausedUntil, now < pausedUntil { return }
        let targets: [Target]
        do {
            targets = try await self.targets(in: try await context.snapshot())
        } catch {
            log("やめた epic を読めないので、開いている PR を閉じるのは次の周でやり直す（\(error)）")
            return
        }
        let ids = Set(targets.map(\.epic.id))
        nextCheck = nextCheck.filter { ids.contains($0.key) }
        uncommented = uncommented.filter { ids.contains($0.key) }
        for target in targets {
            let epic = target.epic
            if let next = nextCheck[epic.id], now < next { continue }
            do {
                let pass = try await close(target)
                report(pass, of: epic)
                let wait = pass.commentFailures.isEmpty ? settings.recheckInterval : settings.retryInterval
                nextCheck[epic.id] = context.now().addingTimeInterval(Self.seconds(wait))
            } catch {
                log("やめた epic \(epic.id)（\(epic.repo)）の開いている PR を閉じられない（\(error)）。後でやり直す")
                // 待つ長さは、断られた時刻から数える
                let failedAt = context.now()
                guard case let .rateLimited(retryAfter) = error else {
                    nextCheck[epic.id] = failedAt.addingTimeInterval(Self.seconds(settings.retryInterval))
                    continue
                }
                pausedUntil = failedAt.addingTimeInterval(Self.seconds(max(retryAfter, settings.retryInterval)))
                return
            }
        }
    }

    private func report(_ pass: Pass, of epic: EpicFile) {
        if !pass.closed.isEmpty {
            let numbers = pass.closed.map { "#\($0)" }.joined(separator: "・")
            log("やめた epic \(epic.id)（\(epic.repo)）の開いている PR \(numbers) を、マージせずに閉じた")
        }
        for (number, error) in pass.commentFailures.sorted(by: { $0.key < $1.key }) {
            log("やめた epic \(epic.id)（\(epic.repo)）の閉じた PR #\(number) に、取り下げたことのコメントを書けない（\(error)）。後で書き直す")
        }
    }

    /// 見る epic: 開始していたやめた epic のうち、やめてから `window` に `recheckInterval` を足した間のもの（期限の後にも 1 回探すため）と、
    /// 書き直すコメントが残っているもの
    private func targets(in reader: CommanderContext) async throws(CommanderError) -> [Target] {
        let now = context.now()
        let period = Self.seconds(settings.window) + Self.seconds(settings.recheckInterval)
        var targets: [Target] = []
        for repo in try await reader.repositories() {
            let epics = try await reader.epics(of: repo) { $0.stage == .abandoned && $0.mac != nil }
            for epic in epics {
                let searches = now.timeIntervalSince(epic.updatedAt.date) < period
                guard searches || uncommented[epic.id]?.isEmpty == false else { continue }
                let repository = try await reader.readable(RepositoryFile.self, at: StatePath.repository(repo))?.build?.baseBranch
                let base = epic.release.map(SubmissionFile.branchName(for:)) ?? repository
                targets.append(Target(epic: epic, base: base, searches: searches))
            }
        }
        return targets
    }

    /// epic の開いている子 PR と最終 PR を閉じ、取り下げたことのコメントを書く。コメントだけの失敗は、その PR を後に回して続ける
    /// （ほかの PR を閉じるのを止めない）。上限とコメント以外の失敗は投げる
    func close(_ target: Target) async throws(PullRequestError) -> Pass {
        let epic = target.epic
        var pass = Pass()
        for number in (uncommented[epic.id] ?? []).sorted() {
            try await comment(number, of: epic, pass: &pass)
        }
        guard target.searches else { return pass }
        let branch = epic.branch ?? PrepareWorkspaceRunner.branch(of: epic.id)
        let children = try await github.openPullRequests(epic.repo, head: nil, base: branch)
        let finals = try await github.openPullRequests(epic.repo, head: branch, base: target.base)
        for pull in children + finals where !pass.closed.contains(pull.number) {
            // 閉じてからコメントを書く（先にコメントを書くと、閉じられずにやり直したときにコメントが重なる）
            try await github.close(epic.repo, number: pull.number)
            pass.closed.append(pull.number)
            uncommented[epic.id, default: []].insert(pull.number)
            try await comment(pull.number, of: epic, pass: &pass)
        }
        return pass
    }

    /// 閉じた PR にコメントを書く。上限なら投げ、ほかの失敗は `pass` に残して、次に見るときに書き直す
    private func comment(_ number: Int, of epic: EpicFile, pass: inout Pass) async throws(PullRequestError) {
        do {
            try await github.comment(epic.repo, number: number, body: Self.comment(for: epic))
            uncommented[epic.id]?.remove(number)
        } catch {
            if case .rateLimited = error { throw error }
            pass.commentFailures[number] = error
        }
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
