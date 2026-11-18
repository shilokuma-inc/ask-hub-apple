import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 管理用のトークンで GitHub を操作する部品を作るもの（`docs/renewal/security.md` の「管理用のトークン」）。
/// 人の意図の処理（`CommanderLoop` の `handlers`）にだけ渡す。ジョブ・ワーカー・git には渡さない
public struct AdminGitHub: Sendable {
    public var tokens: AdminTokens
    public var transport: any HTTPTransport
    public var apiBase: URL

    public init(tokens: AdminTokens, transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.tokens = tokens
        self.transport = transport
        self.apiBase = apiBase
    }

    /// リポジトリの持ち主の管理用のトークンで操作する部品。トークンが無い・読めなければ、断る理由
    func pullRequests(for repo: RepositoryFullName) -> Result<GitHubPullRequests, AdminTokenProblem> {
        tokens.token(for: repo.owner).map { token in
            GitHubPullRequests(repository: repo, apiBase: apiBase, transport: transport) { _ in token }
        }
    }
}

/// 保護の設定（`applyProtection`）を受け付け、管理用のトークンでルールセット `askhub-protect` を掛け、重なる保護を外す
/// （`docs/renewal/operations.md` の「保護の設定」）。
///
/// 先にルールセットを掛けてから重なるものを外す（途中で失敗しても、保護が無い時間を作らない）。掛けたら `repo.json` の `protection` を書く。
/// 外せなかったものがあれば、書いた上で理由を付けて断る（押し直すと、残りを外す）
public struct ApplyProtectionHandler: IntentHandler {
    public var admin: AdminGitHub?

    public init(admin: AdminGitHub?) {
        self.admin = admin
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let apply: ApplyProtectionIntent
        do {
            apply = try ApplyProtectionIntent(envelope: envelope)
        } catch {
            return .reject("保護の設定の形が違う（\(error.detail)）")
        }
        let path = StatePath.repository(apply.repo)
        guard let repository = try await context.read(RepositoryFile.self, at: path) else {
            return .reject("\(apply.repo) は対象のリポジトリに加えていない。先に対象に加える")
        }
        guard !repository.isRemoved else { return .reject("\(apply.repo) は対象から外した。保護を掛けるには加え直す") }
        guard let admin else { return .reject("この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）") }
        let github: GitHubPullRequests
        switch admin.pullRequests(for: apply.repo) {
        case let .success(made): github = made
        case let .failure(problem): return .reject(problem.description)
        }
        let outcome: ProtectionApplier.Outcome
        do {
            outcome = try await ProtectionApplier(github: github).apply(requiredChecks: apply.requiredChecks)
        } catch {
            return .reject(ProtectionApplier.reason(error, repo: apply.repo))
        }
        // 同じルールセットへの掛け直し（外しきれずに押し直したとき）は、前に外したものも残す（外した保護は GitHub の一覧に出なくなるため）
        let previous = repository.protection.rulesetId == outcome.rulesetID ? repository.protection.replaced ?? [] : []
        let protection = RepositoryFile.Protection(
            appliedAt: context.timestamp,
            requiredChecks: apply.requiredChecks,
            rulesetId: outcome.rulesetID,
            replaced: previous + outcome.replaced.filter { !previous.contains($0) },
            remaining: outcome.remaining
        )
        do {
            try await context.files.update(RepositoryFile.self, at: path, message: "\(apply.repo) に保護を掛けた") {
                $0.protection = protection
                return true
            }
        } catch {
            throw .files(error)
        }
        guard outcome.failures.isEmpty else {
            return .reject("ルールセットは掛けたが、重なる保護を外しきれなかった: \(outcome.failures.joined(separator: "・"))。もう一度押すと残りを外す")
        }
        return .accept
    }
}

/// ルールセットを掛け、守る範囲に収まる保護を外す。範囲の外も守る保護は、外すとほかのブランチの保護が消えるので、残して知らせる
struct ProtectionApplier {
    struct Outcome: Equatable {
        var rulesetID: Int
        var replaced: [ExistingProtection]
        var remaining: [ExistingProtection]
        /// 外せなかった・読めなかったもの（人が読む文）
        var failures: [String]
        /// GitHub の上限に当たり、残りを確かめずに止めた（同じトークンで続けて送らない）。上限でなければ nil
        var stoppedFor: Duration?
    }

    var github: GitHubPullRequests

    func apply(requiredChecks: [String]) async throws(PullRequestError) -> Outcome {
        let settings = try await github.repositorySettings()
        let summaries = try await github.branchRulesets()
        let existing = summaries.first { $0.source == .repository && $0.name == ProtectionPolicy.rulesetName }
        // 先に掛ける。ここで失敗したら、何も外さない
        let applied = try await github.putRuleset(ProtectionRules.draft(requiredChecks: requiredChecks), id: existing?.id)
        var outcome = Outcome(rulesetID: applied.id, replaced: [], remaining: [], failures: [])
        for summary in summaries where summary.id != applied.id && outcome.stoppedFor == nil {
            await replace(summary, defaultBranch: settings.defaultBranch, into: &outcome)
        }
        if outcome.stoppedFor == nil { await replaceClassicRules(into: &outcome) }
        if let wait = outcome.stoppedFor {
            outcome.failures.append("GitHub の上限に当たったので、残りの保護を確かめずに止めた（\(wait.components.seconds) 秒ほど待ってから押し直す）")
        }
        return outcome
    }

    /// 重なるルールセットを外す。範囲の外も守るもの・organization のもの（リポジトリの側からは外せない）は、残したものとして書く
    private func replace(_ summary: RulesetSummary, defaultBranch: String, into outcome: inout Outcome) async {
        let ruleset: Ruleset
        do throws(PullRequestError) {
            ruleset = try await github.ruleset(id: summary.id)
        } catch {
            record(error, as: "ルールセット \(summary.name) を読めない", into: &outcome)
            return
        }
        switch (ruleset.source, ProtectionRules.coverage(ruleset: ruleset, defaultBranch: defaultBranch)) {
        case (_, .disjoint):
            return
        case (.organization, _):
            outcome.remaining.append(.init(kind: .organizationRuleset, name: ruleset.name, reason: "organization のルールセットは、リポジトリの側からは外せない"))
        case (.repository, .broader):
            outcome.remaining.append(.init(kind: .ruleset, name: ruleset.name, reason: Self.broaderReason))
        case (.repository, .within):
            do throws(PullRequestError) {
                try await github.deleteRuleset(id: ruleset.id)
                outcome.replaced.append(.init(kind: .ruleset, name: ruleset.name))
            } catch {
                outcome.remaining.append(.init(kind: .ruleset, name: ruleset.name, reason: "外せなかった（\(Self.describe(error))）"))
                record(error, as: "ルールセット \(ruleset.name) を外せない", into: &outcome)
            }
        }
    }

    /// 守る範囲に収まるクラシックの保護を外す。範囲の外も守るものは残したものとして書く
    private func replaceClassicRules(into outcome: inout Outcome) async {
        let rules: [BranchProtectionRule]
        do throws(PullRequestError) {
            rules = try await github.branchProtectionRules()
        } catch {
            record(error, as: "クラシックの保護を読めない", into: &outcome)
            return
        }
        for rule in rules where outcome.stoppedFor == nil {
            switch ProtectionRules.coverage(classic: rule.pattern) {
            case .disjoint:
                continue
            case .broader:
                outcome.remaining.append(.init(kind: .classic, name: rule.pattern, reason: Self.broaderReason))
            case .within:
                do throws(PullRequestError) {
                    try await github.deleteBranchProtectionRule(id: rule.id)
                    outcome.replaced.append(.init(kind: .classic, name: rule.pattern))
                } catch {
                    outcome.remaining.append(.init(kind: .classic, name: rule.pattern, reason: "外せなかった（\(Self.describe(error))）"))
                    record(error, as: "クラシックの保護 \(rule.pattern) を外せない", into: &outcome)
                }
            }
        }
    }

    /// 失敗を書く。上限なら、続けて送らないよう止める
    private func record(_ error: PullRequestError, as what: String, into outcome: inout Outcome) {
        if case let .rateLimited(wait) = error {
            outcome.stoppedFor = wait
            return
        }
        outcome.failures.append("\(what)（\(Self.describe(error))）")
    }

    static let broaderReason = "守るブランチのほかにも掛かる（かもしれない）ので、ほかのブランチの保護を消さないよう外さなかった。要らなければ GitHub の画面で外す"

    /// 掛けられなかった理由（人が読む文）
    static func reason(_ error: PullRequestError, repo: RepositoryFullName) -> String {
        switch error {
        case let .forbidden(message) where message?.localizedCaseInsensitiveContains("upgrade") == true:
            "\(repo) は private のリポジトリで、今のプランではルールセットを掛けられない（GitHub: \(message ?? "")）"
        case let .forbidden(message):
            "管理用のトークンで断られた（Administration の書き込みが無いか、Repository access に \(repo) が無い。GitHub: \(message ?? "")）"
        case .notFound:
            "\(repo) が見つからない（管理用のトークンの Repository access に入っていない）"
        case .unauthorized:
            "\(repo.owner) の管理用のトークンが使えない（期限切れ・取り消し。askhub-commander admin-token \(repo.owner) で入れ直す）"
        case let .rejected(message):
            "GitHub がルールセットを断った（\(message ?? "理由は書かれていない")）"
        case .rateLimited, .serverError, .transport, .cancelled:
            "GitHub に届かない・混んでいる（\(describe(error))）。少し待ってから押し直す"
        default:
            "保護を掛けられない（\(describe(error))）"
        }
    }

    static func describe(_ error: PullRequestError) -> String {
        String(describing: error)
    }
}
