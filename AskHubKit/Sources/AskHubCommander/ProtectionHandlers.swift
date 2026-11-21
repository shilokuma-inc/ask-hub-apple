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
    /// 上限に当たった持ち主（写しの間で分け合う）
    let pauses = AdminPauses()

    public init(tokens: AdminTokens, transport: any HTTPTransport, apiBase: URL = URL(string: "https://api.github.com")!) {
        self.tokens = tokens
        self.transport = transport
        self.apiBase = apiBase
    }

    /// リポジトリの持ち主の管理用のトークンで操作する部品。トークンが無い・読めない・上限で待っている間なら、送らずに断るわけ
    func pullRequests(for repo: RepositoryFullName, now: Date) async -> Result<GitHubPullRequests, AdminRefusal> {
        if let wait = await pauses.wait(for: repo.owner, now: now) { return .failure(.rateLimited(owner: repo.owner, wait: wait)) }
        switch tokens.token(for: repo.owner) {
        case let .success(token):
            return .success(GitHubPullRequests(repository: repo, apiBase: apiBase, transport: transport) { _ in token })
        case let .failure(problem): return .failure(.token(problem))
        }
    }

    /// 上限に当たったことを書く。待つ時間が過ぎるまで、持ち主の管理の操作は（ほかの人の意図でも）送らない
    func pause(_ owner: String, for wait: Duration, now: Date) async {
        await pauses.pause(owner, for: wait, now: now)
    }

    /// GitHub の失敗が上限なら、上限に当たったことを書く
    func note(_ error: PullRequestError, owner: String, now: Date) async {
        if case let .rateLimited(wait) = error { await pause(owner, for: wait, now: now) }
    }
}

/// 管理の操作を GitHub に送らずに断るわけ
enum AdminRefusal: Error, Equatable, CustomStringConvertible {
    case token(AdminTokenProblem)
    /// 持ち主の管理用のトークンが上限に当たって待っている（残りの時間）
    case rateLimited(owner: String, wait: Duration)

    var description: String {
        switch self {
        case let .token(problem): problem.description
        case let .rateLimited(owner, wait):
            "\(owner) の管理用のトークンは GitHub の上限に当たっているので、送らなかった（\(wait.components.seconds) 秒ほど待ってから押し直す）"
        }
    }
}

/// 管理用のトークンが GitHub の上限に当たった持ち主と、次に送ってよい時刻。上限はアカウントで数えるので、人の意図をまたいで分け合う
actor AdminPauses {
    private var until: [String: Date] = [:]

    func wait(for owner: String, now: Date) -> Duration? {
        guard let end = until[owner.lowercased()], end > now else { return nil }
        return .seconds(Int(end.timeIntervalSince(now).rounded(.up)))
    }

    func pause(_ owner: String, for wait: Duration, now: Date) {
        let key = owner.lowercased()
        let end = now.addingTimeInterval(TimeInterval(wait.components.seconds))
        until[key] = max(until[key] ?? end, end)
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
        switch await admin.pullRequests(for: apply.repo, now: context.now()) {
        case let .success(made): github = made
        case let .failure(refusal): return .reject(refusal.description)
        }
        let outcome: ProtectionApplier.Outcome
        switch await Self.applying(apply, github: github, admin: admin, now: context.now) {
        case let .success(made): outcome = made
        case let .failure(failure): return .reject(ProtectionApplier.reason(failure, repo: apply.repo))
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

    /// 掛ける。上限に当たったら、持ち主の管理の操作をしばらく送らない
    private static func applying(
        _ apply: ApplyProtectionIntent,
        github: GitHubPullRequests,
        admin: AdminGitHub,
        now: @Sendable () -> Date
    ) async -> Result<ProtectionApplier.Outcome, ProtectionApplier.Failure> {
        do throws(ProtectionApplier.Failure) {
            let outcome = try await ProtectionApplier(github: github).apply(requiredChecks: apply.requiredChecks)
            if let wait = outcome.stoppedFor { await admin.pause(apply.repo.owner, for: wait, now: now()) }
            return .success(outcome)
        } catch {
            if case let .github(error) = error { await admin.note(error, owner: apply.repo.owner, now: now()) }
            return .failure(error)
        }
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

    /// 掛けられなかったわけ（何も変えていない）
    enum Failure: Error, Equatable {
        case github(PullRequestError)
        /// 同じ名前のルールセットが、守る範囲の外にも掛かる（かもしれない）。置き換えると、そのブランチの保護が消える
        case existingBeyondPolicy
    }

    var github: GitHubPullRequests

    func apply(requiredChecks: [String]) async throws(Failure) -> Outcome {
        let current: Current
        do throws(PullRequestError) {
            current = try await read()
        } catch {
            throw .github(error)
        }
        if let existing = current.existing, !existing.includes.isEmpty,
           ProtectionRules.coverage(ruleset: existing, defaultBranch: current.settings.defaultBranch) != .within {
            throw .existingBeyondPolicy
        }
        // 先に掛ける。ここで失敗したら、何も外さない
        let applied: Ruleset
        do throws(PullRequestError) {
            applied = try await github.putRuleset(ProtectionRules.draft(requiredChecks: requiredChecks), id: current.existing?.id)
        } catch {
            throw .github(error)
        }
        var outcome = Outcome(rulesetID: applied.id, replaced: [], remaining: [], failures: [])
        // 掛けた結果が決まりの形でなければ（例外が残ったなど）、ほかの保護を外すと守りが弱くなるので、何も外さない
        let problems = ProtectionRules.drift(of: applied, requiredChecks: requiredChecks)
        guard problems.isEmpty else {
            outcome.failures.append("掛けたルールセットが決まりの形にならなかったので、何も外さなかった（\(problems.joined(separator: "・"))）")
            return outcome
        }
        for summary in current.summaries where summary.id != applied.id && outcome.stoppedFor == nil {
            await replace(summary, defaultBranch: current.settings.defaultBranch, into: &outcome)
        }
        if outcome.stoppedFor == nil { await replaceClassicRules(into: &outcome) }
        if let wait = outcome.stoppedFor {
            outcome.failures.append("GitHub の上限に当たったので、残りの保護を確かめずに止めた（\(wait.components.seconds) 秒ほど待ってから押し直す）")
        }
        return outcome
    }

    /// 掛ける前に読むもの
    private struct Current {
        var settings: RepositorySettings
        var summaries: [RulesetSummary]
        /// 置き換える同じ名前のルールセットの中身。無ければ nil（作る）
        var existing: Ruleset?
    }

    private func read() async throws(PullRequestError) -> Current {
        let settings = try await github.repositorySettings()
        let summaries = try await github.branchRulesets()
        let summary = summaries.first { $0.source == .repository && $0.name == ProtectionPolicy.rulesetName }
        guard let summary else { return Current(settings: settings, summaries: summaries, existing: nil) }
        return Current(settings: settings, summaries: summaries, existing: try await github.ruleset(id: summary.id))
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
    static func reason(_ failure: Failure, repo: RepositoryFullName) -> String {
        switch failure {
        case let .github(error):
            reason(error, repo: repo)
        case .existingBeyondPolicy:
            "\(repo) に今あるルールセット \(ProtectionPolicy.rulesetName) は、守るブランチ（develop・main・release/ の下）のほかにも掛かる（かもしれない）。" +
                "置き換えるとそのブランチの保護が消えるので、何も変えなかった。GitHub の画面で \(ProtectionPolicy.rulesetName) の対象を直すか、名前を変えてから押し直す"
        }
    }

    private static func reason(_ error: PullRequestError, repo: RepositoryFullName) -> String {
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
