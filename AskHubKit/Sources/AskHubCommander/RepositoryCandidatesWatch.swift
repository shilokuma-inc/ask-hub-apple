import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 「対象に加える」の候補（`repo-candidates.json`）を、毎日のトークンを置いた持ち主ごとに読んで書く
/// （`docs/renewal/operations.md` の「対象のリポジトリ」。クライアントのトークンは状態リポジトリしか読めないので、司令塔が代わりに読む）。
///
/// 自動で読むので、管理用のトークンは使わず、毎日のトークン（Metadata の読み取り）で読むだけにする。
/// 司令塔が生きている印を書くときに `start()` を呼び、`interval`（1 時間）ごとに読み直す。中身が変わったときだけ書く
public actor RepositoryCandidatesWatch {
    nonisolated let context: CommanderContext
    /// 毎日のトークンを置いた持ち主（呼ぶたびに設定を読み直す。`MachineConfiguration.tokenOwnersReloading`）
    nonisolated let owners: @Sendable () -> [String]
    /// 持ち主を受け取り、毎日のトークンで一覧を読む部品を返す
    nonisolated let listing: @Sendable (String) -> GitHubOwnerRepositories?
    /// 状態リポジトリ（候補に入れない）
    nonisolated let stateRepository: RepositoryFullName
    nonisolated let log: @Sendable (String) -> Void
    nonisolated let interval: TimeInterval
    private var readAt: Date?
    private var running = false

    public init(
        context: CommanderContext,
        owners: @escaping @Sendable () -> [String],
        listing: @escaping @Sendable (String) -> GitHubOwnerRepositories?,
        stateRepository: RepositoryFullName,
        log: @escaping @Sendable (String) -> Void,
        interval: Duration = .seconds(60 * 60)
    ) {
        self.context = context
        self.owners = owners
        self.listing = listing
        self.stateRepository = stateRepository
        self.log = log
        self.interval = TimeInterval(interval.components.seconds)
    }

    /// 読み直す時期なら、周の外で読み始める。前に始めたものが終わっていなければ、何もしない
    nonisolated public func start() {
        Task { await readIfDue() }
    }

    /// 次の `start()` で読み直す（テンプレートからリポジトリを作った後など、一覧が変わったと分かっているとき）
    public func expire() {
        readAt = nil
    }

    func readIfDue() async {
        guard !running, readAt.map({ context.now().timeIntervalSince($0) >= interval }) ?? true else { return }
        running = true
        defer { running = false }
        do {
            try await refresh()
        } catch {
            log("対象に加える候補を書けない（\(error)）。次の生きている印のときにやり直す")
            return
        }
        readAt = context.now()
    }

    /// 持ち主ごとに一覧を読み、前と変わっていれば書く。書いたら true
    @discardableResult
    func refresh() async throws(CommanderError) -> Bool {
        let path = StatePath.repositoryCandidates
        let previous = try await context.readable(RepositoryCandidatesFile.self, at: path)
        var owners: [RepositoryCandidatesFile.Owner] = []
        var stopped = false
        for owner in self.owners() {
            let before = previous?.owners.first { $0.owner.lowercased() == owner.lowercased() }
            // 上限に当たったら、残りの持ち主は前の一覧のまま（上限はアカウントで数えるので、続けて読まない）
            if stopped {
                owners.append(before ?? .init(owner: owner))
                continue
            }
            do throws(PullRequestError) {
                guard let listing = listing(owner) else { throw .invalidArgument("持ち主の名前の形でない") }
                let candidates = Self.candidates(try await listing.repositories(), excluding: stateRepository)
                if let before, before.repositories == candidates, before.problem == nil {
                    owners.append(before)
                } else {
                    owners.append(.init(owner: owner, readAt: context.timestamp, repositories: candidates))
                }
            } catch {
                if case let .rateLimited(wait) = error {
                    log("対象に加える候補を読む途中で GitHub の上限に当たった（\(wait.components.seconds) 秒）。残りは次に読み直すときに読む")
                    stopped = true
                }
                let problem = Self.reason(owner: owner, error)
                owners.append(.init(owner: owner, readAt: before?.readAt, repositories: before?.repositories ?? [], problem: problem))
            }
        }
        let file = RepositoryCandidatesFile(owners: owners)
        guard file != previous else { return false }
        try await write(file)
        return true
    }

    nonisolated private func write(_ file: RepositoryCandidatesFile) async throws(CommanderError) {
        try await context.writingResult { () throws(CommanderError) in
            try await context.put(file, at: StatePath.repositoryCandidates, message: "対象に加える候補を書く")
        }
    }

    /// 候補にするリポジトリ（アーカイブ・テンプレート・状態リポジトリを除き、名前の順。多ければ最近 push したものから残す）
    static func candidates(
        _ repositories: [OwnerRepository],
        excluding stateRepository: RepositoryFullName
    ) -> [RepositoryCandidatesFile.Repository] {
        let kept = repositories.filter { repository in
            !repository.isArchived && !repository.isTemplate
                && "\(repository.owner)/\(repository.name)".lowercased() != stateRepository.rawValue.lowercased()
                && RepositoryFullName(rawValue: "\(repository.owner)/\(repository.name)") != nil
        }
        let recent = kept.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
            .prefix(RepositoryCandidatesFile.maximumRepositories)
        var seen = Set<String>()
        return recent
            .filter { seen.insert($0.name.lowercased()).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { repository in
                RepositoryCandidatesFile.Repository(
                    name: repository.name,
                    isPrivate: repository.isPrivate,
                    description: repository.description.flatMap(Self.description),
                    pushedAt: repository.pushedAt.map(Timestamp.init)
                )
            }
    }

    /// 説明を 1 行にそろえ、上限で切る。空なら nil
    static func description(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        let limit = RepositoryCandidatesFile.maximumDescriptionLength
        guard line.unicodeScalars.count > limit else { return line }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: line.unicodeScalars.prefix(limit - 1))
        return String(scalars) + "…"
    }

    static func reason(owner: String, _ error: PullRequestError) -> String {
        switch error {
        case .tokenUnavailable: "\(owner) の毎日のトークンが無い・読めない（常時オンの Mac で askhub-commander token \(owner) を流して入れる）"
        case .unauthorized: "\(owner) の毎日のトークンで一覧を読めない（期限切れ・取り消し）"
        case .notFound: "\(owner) が見つからない（持ち主の名前を確かめる）"
        case let .rateLimited(wait): "GitHub の上限に当たったので読めなかった（\(wait.components.seconds) 秒ほど待ってから読み直す）"
        default: "\(owner) のリポジトリの一覧を読めない（\(error)）"
        }
    }
}
