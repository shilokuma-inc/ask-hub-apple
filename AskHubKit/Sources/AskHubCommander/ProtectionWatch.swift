import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 掛けた保護（ルールセット `askhub-protect`）のずれを点検し、`repo.json` の `protection.drift` に書く
/// （`docs/renewal/security.md` の「ブランチ保護」。クライアントが「あなたの番」に出す）。
///
/// 自動で行うので、管理用のトークンは使わず、毎日のトークン（Metadata の読み取り）でルールセットを読むだけにする。直すのは、人が保護の設定を押し直したとき。
/// 司令塔が生きている印を書くときに `start()` を呼び、保護を掛けたリポジトリを `interval` ごとに 1 つずつ確かめる。ずれが変わったときだけ書く
public actor ProtectionWatch {
    nonisolated let context: CommanderContext
    /// リポジトリを受け取り、毎日のトークンで読む部品を返す
    nonisolated let github: @Sendable (RepositoryFullName) -> GitHubPullRequests
    nonisolated let log: @Sendable (String) -> Void
    nonisolated let interval: TimeInterval
    private var checkedAt: [RepositoryFullName: Date] = [:]
    private var running = false

    public init(
        context: CommanderContext,
        github: @escaping @Sendable (RepositoryFullName) -> GitHubPullRequests,
        log: @escaping @Sendable (String) -> Void,
        interval: Duration = .seconds(6 * 60 * 60)
    ) {
        self.context = context
        self.github = github
        self.log = log
        self.interval = TimeInterval(interval.components.seconds)
    }

    /// 確かめる時期のリポジトリを、周の外で確かめ始める。前に始めたものが終わっていなければ、何もしない
    nonisolated public func start() {
        Task { await checkDue() }
    }

    func checkDue() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let repositories: [RepositoryFullName]
        do {
            repositories = try await context.repositories()
        } catch {
            log("保護のずれを確かめるリポジトリの一覧を読めない（\(error)）。次の生きている印のときにやり直す")
            return
        }
        for repo in repositories where isDue(repo) {
            do {
                try await check(repo)
            } catch {
                log("\(repo) の保護のずれを確かめられない（\(error)）。次に確かめるときにやり直す")
            }
            checkedAt[repo] = context.now()
        }
    }

    private func isDue(_ repo: RepositoryFullName) -> Bool {
        guard let checked = checkedAt[repo] else { return true }
        return context.now().timeIntervalSince(checked) >= interval
    }

    /// 保護を掛けたリポジトリのずれを読み、前と変わっていれば書く。書いたら true
    @discardableResult
    func check(_ repo: RepositoryFullName) async throws -> Bool {
        let path = StatePath.repository(repo)
        // 対象から外したリポジトリは点検しない（GitHub 側には触れないので、保護は掛かったまま）
        guard let file = try await context.readable(RepositoryFile.self, at: path), !file.isRemoved,
              file.protection.appliedAt != nil else { return false }
        let problems = try await Self.problems(
            github: github(repo), requiredChecks: file.protection.requiredChecks ?? ProtectionPolicy.defaultRequiredChecks
        )
        guard problems != (file.protection.drift?.problems ?? []) else { return false }
        try await write(problems.isEmpty ? nil : .init(foundAt: context.timestamp, problems: problems), for: repo)
        log(problems.isEmpty ? "\(repo) の保護のずれが無くなった" : "\(repo) の保護がずれている: \(problems.joined(separator: "・"))")
        return true
    }

    /// ずれを書く。保護を掛けていない（掛け直す前に外れた）・同じずれなら書かない
    nonisolated private func write(_ drift: ProtectionDrift?, for repo: RepositoryFullName) async throws(CommanderError) {
        let path = StatePath.repository(repo)
        try await context.writingResult { () throws(CommanderError) in
            do throws(StateFileStore.Failure) {
                try await context.files.update(RepositoryFile.self, at: path, message: "\(repo) の保護のずれを書く") { file in
                    guard file.protection.appliedAt != nil, file.protection.drift?.problems != drift?.problems else { return false }
                    file.protection.drift = drift
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
    }

    /// 掛けたルールセットのずれと、あとから重なったリポジトリのルールセット（人が読む文）。ずれていなければ空
    static func problems(github: GitHubPullRequests, requiredChecks: [String]) async throws(PullRequestError) -> [String] {
        let summaries = try await github.branchRulesets()
        guard let ours = summaries.first(where: { $0.source == .repository && $0.name == ProtectionPolicy.rulesetName }) else {
            return ["ルールセット \(ProtectionPolicy.rulesetName) が無い（外された）"]
        }
        var problems = ProtectionRules.drift(of: try await github.ruleset(id: ours.id), requiredChecks: requiredChecks)
        let others = summaries.filter { $0.id != ours.id && $0.source == .repository }
        guard !others.isEmpty else { return problems }
        let defaultBranch = try await github.repositorySettings().defaultBranch
        for summary in others {
            let ruleset = try await github.ruleset(id: summary.id)
            if ProtectionRules.overlaps(ruleset: ruleset, defaultBranch: defaultBranch) {
                problems.append("ほかのルールセット \(summary.name) が重なっている")
            }
        }
        return problems
    }
}
