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
        guard try await context.read(RepositoryFile.self, at: path) != nil else {
            return .reject("\(apply.repo) は対象のリポジトリに加えていない。先に対象に加える")
        }
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
        let protection = RepositoryFile.Protection(
            appliedAt: context.timestamp,
            requiredChecks: apply.requiredChecks,
            rulesetId: outcome.rulesetID,
            replaced: outcome.replaced,
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

/// ルールセットを掛け、重なる保護を外す
struct ProtectionApplier {
    struct Outcome: Equatable {
        var rulesetID: Int
        var replaced: [ExistingProtection]
        var remaining: [ExistingProtection]
        /// 外せなかった・読めなかったもの（人が読む文）
        var failures: [String]
    }

    var github: GitHubPullRequests

    func apply(requiredChecks: [String]) async throws(PullRequestError) -> Outcome {
        let settings = try await github.repositorySettings()
        let summaries = try await github.branchRulesets()
        let existing = summaries.first { $0.source == .repository && $0.name == ProtectionPolicy.rulesetName }
        // 先に掛ける。ここで失敗したら、何も外さない
        let applied = try await github.putRuleset(ProtectionRules.draft(requiredChecks: requiredChecks), id: existing?.id)
        var outcome = Outcome(rulesetID: applied.id, replaced: [], remaining: [], failures: [])
        for summary in summaries where summary.id != applied.id {
            await replace(summary, defaultBranch: settings.defaultBranch, into: &outcome)
        }
        await replaceClassicRules(defaultBranch: settings.defaultBranch, into: &outcome)
        return outcome
    }

    /// 重なるルールセットを外す。organization のものは外せないので、残ったものとして書く
    private func replace(_ summary: RulesetSummary, defaultBranch: String, into outcome: inout Outcome) async {
        do throws(PullRequestError) {
            let ruleset = try await github.ruleset(id: summary.id)
            guard ProtectionRules.overlaps(ruleset: ruleset, defaultBranch: defaultBranch) else { return }
            switch ruleset.source {
            case .repository:
                try await github.deleteRuleset(id: ruleset.id)
                outcome.replaced.append(.init(kind: .ruleset, name: ruleset.name))
            case .organization:
                outcome.remaining.append(.init(kind: .organizationRuleset, name: ruleset.name))
            }
        } catch {
            outcome.failures.append("ルールセット \(summary.name)（\(Self.describe(error))）")
        }
    }

    /// 重なるクラシックの保護を外す
    private func replaceClassicRules(defaultBranch: String, into outcome: inout Outcome) async {
        let rules: [BranchProtectionRule]
        do throws(PullRequestError) {
            rules = try await github.branchProtectionRules()
        } catch {
            outcome.failures.append("クラシックの保護を読めない（\(Self.describe(error))）")
            return
        }
        for rule in rules where ProtectionRules.overlaps(classic: rule.pattern, defaultBranch: defaultBranch) {
            do throws(PullRequestError) {
                try await github.deleteBranchProtectionRule(id: rule.id)
                outcome.replaced.append(.init(kind: .classic, name: rule.pattern))
            } catch {
                outcome.failures.append("クラシックの保護 \(rule.pattern)（\(Self.describe(error))）")
            }
        }
    }

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
