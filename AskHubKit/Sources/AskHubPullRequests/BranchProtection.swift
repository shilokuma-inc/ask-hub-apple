import AskHubProtocol
import Foundation

/// リポジトリの設定（`GET /repos/{owner}/{repo}`）のうち、保護と対象に加えるときの準備に使うもの
public struct RepositorySettings: Equatable, Sendable {
    public var defaultBranch: String
    public var isPrivate: Bool
    public var hasDiscussions: Bool

    public init(defaultBranch: String, isPrivate: Bool, hasDiscussions: Bool) {
        self.defaultBranch = defaultBranch
        self.isPrivate = isPrivate
        self.hasDiscussions = hasDiscussions
    }
}

/// ルールセットの持ち主
public enum RulesetSource: Equatable, Sendable {
    /// リポジトリのルールセット（司令塔が置き換えたり外したりできる）
    case repository
    /// organization のルールセット（リポジトリの側からは外せない）
    case organization(String)
}

/// ルールセットの一覧の 1 つ（中身は `Ruleset`）
public struct RulesetSummary: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var source: RulesetSource

    public init(id: Int, name: String, source: RulesetSource) {
        self.id = id
        self.name = name
        self.source = source
    }
}

/// ブランチのルールセットの中身
public struct Ruleset: Equatable, Sendable {
    public enum Rule: Equatable, Sendable {
        case deletion
        case nonFastForward
        /// PR 必須（要る承認の数と、マージを止める承認の条件）
        case pullRequest(PullRequestRule)
        /// 必須のチェック（名前と、出してよいアプリ。ブランチを作るときに止めないか）
        case requiredStatusChecks(StatusChecksRule)
        /// ほかの種類（`type` の値）
        case other(String)
    }

    public struct RequiredCheck: Equatable, Sendable {
        public var context: String
        public var integrationID: Int?

        public init(context: String, integrationID: Int?) {
            self.context = context
            self.integrationID = integrationID
        }
    }

    public var id: Int
    public var name: String
    public var source: RulesetSource
    /// `active`・`evaluate`・`disabled`
    public var enforcement: String
    /// 対象のブランチ（`refs/heads/…`・`~DEFAULT_BRANCH`・`~ALL`）
    public var includes: [String]
    public var excludes: [String]
    public var rules: [Rule]
    /// 例外にした者の数。読んだトークンに見えなければ nil（管理の権限が無いと返らない）
    public var bypassActorCount: Int?

    public init(
        id: Int,
        name: String,
        source: RulesetSource,
        enforcement: String,
        includes: [String],
        excludes: [String],
        rules: [Rule],
        bypassActorCount: Int?
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.enforcement = enforcement
        self.includes = includes
        self.excludes = excludes
        self.rules = rules
        self.bypassActorCount = bypassActorCount
    }
}

/// PR 必須の規則のうち、マージを止める条件（どれかが入ると、同じアカウントだけでは PR をマージできなくなる）
public struct PullRequestRule: Equatable, Sendable {
    /// 要る承認の数
    public var requiredApprovals: Int
    /// コードオーナーの承認が要るか
    public var codeOwnerReview: Bool
    /// 最後の push の後の承認が要るか
    public var lastPushApproval: Bool
    /// 会話（レビューのスレッド）をすべて解決する必要があるか
    public var threadResolution: Bool

    public init(requiredApprovals: Int, codeOwnerReview: Bool = false, lastPushApproval: Bool = false, threadResolution: Bool = false) {
        self.requiredApprovals = requiredApprovals
        self.codeOwnerReview = codeOwnerReview
        self.lastPushApproval = lastPushApproval
        self.threadResolution = threadResolution
    }
}

/// 必須のチェックの規則
public struct StatusChecksRule: Equatable, Sendable {
    public var checks: [Ruleset.RequiredCheck]
    /// ブランチを作るときに止めないか。応答に無ければ nil
    public var doNotEnforceOnCreate: Bool?

    public init(checks: [Ruleset.RequiredCheck], doNotEnforceOnCreate: Bool? = nil) {
        self.checks = checks
        self.doNotEnforceOnCreate = doNotEnforceOnCreate
    }
}

/// 作る・置き換えるルールセット（例外なし・有効）
public struct RulesetDraft: Equatable, Sendable {
    public var name: String
    /// 対象のブランチ（`refs/heads/…`）
    public var includes: [String]
    /// 必須のチェックの名前
    public var requiredChecks: [String]
    /// 必須のチェックを出してよいアプリ
    public var checksIntegrationID: Int?

    public init(name: String, includes: [String], requiredChecks: [String], checksIntegrationID: Int?) {
        self.name = name
        self.includes = includes
        self.requiredChecks = requiredChecks
        self.checksIntegrationID = checksIntegrationID
    }
}

/// クラシックのブランチ保護の規則
public struct BranchProtectionRule: Equatable, Sendable {
    /// GraphQL の node id
    public var id: String
    /// 対象のブランチのパターン（fnmatch の形。`*` は `/` をまたがない）
    public var pattern: String

    public init(id: String, pattern: String) {
        self.id = id
        self.pattern = pattern
    }
}

// MARK: - 応答と要求の形

struct RepositorySettingsPayload: Decodable {
    let defaultBranch: String
    let `private`: Bool
    let hasDiscussions: Bool?

    func model() -> RepositorySettings {
        RepositorySettings(defaultBranch: defaultBranch, isPrivate: `private`, hasDiscussions: hasDiscussions ?? false)
    }
}

struct RulesetSummaryPayload: Decodable {
    let id: Int
    let name: String
    let target: String?
    let sourceType: String?
    let source: String?

    func model() -> RulesetSummary {
        RulesetSummary(id: id, name: name, source: Self.source(type: sourceType, name: source))
    }

    static func source(type: String?, name: String?) -> RulesetSource {
        type == "Organization" ? .organization(name ?? "") : .repository
    }
}

struct RulesetPayload: Decodable {
    struct Conditions: Decodable {
        let refName: RefNamePayload?
    }

    let id: Int
    let name: String
    let sourceType: String?
    let source: String?
    let enforcement: String
    let conditions: Conditions?
    let rules: [RulePayload]?
    let bypassActors: [BypassActorPayload]?

    func model() -> Ruleset {
        Ruleset(
            id: id,
            name: name,
            source: RulesetSummaryPayload.source(type: sourceType, name: source),
            enforcement: enforcement,
            includes: conditions?.refName?.include ?? [],
            excludes: conditions?.refName?.exclude ?? [],
            rules: (rules ?? []).map(\.model),
            bypassActorCount: bypassActors?.count
        )
    }
}

/// ルールセットの対象のブランチ（`conditions.ref_name`）
struct RefNamePayload: Decodable {
    let include: [String]?
    let exclude: [String]?
}

/// ルールセットの規則（種類ごとに `parameters` の形が違うので、使う欄だけを任意で読む）
struct RulePayload: Decodable {
    struct Parameters: Decodable {
        let requiredApprovingReviewCount: Int?
        let requireCodeOwnerReview: Bool?
        let requireLastPushApproval: Bool?
        let requiredReviewThreadResolution: Bool?
        let requiredStatusChecks: [RequiredCheckPayload]?
        let doNotEnforceOnCreate: Bool?
    }

    let type: String
    let parameters: Parameters?

    var model: Ruleset.Rule {
        switch type {
        case "deletion": .deletion
        case "non_fast_forward": .nonFastForward
        case "pull_request":
            .pullRequest(PullRequestRule(
                requiredApprovals: parameters?.requiredApprovingReviewCount ?? 0,
                codeOwnerReview: parameters?.requireCodeOwnerReview ?? false,
                lastPushApproval: parameters?.requireLastPushApproval ?? false,
                threadResolution: parameters?.requiredReviewThreadResolution ?? false
            ))
        case "required_status_checks":
            .requiredStatusChecks(StatusChecksRule(
                checks: (parameters?.requiredStatusChecks ?? []).map { .init(context: $0.context, integrationID: $0.integrationId) },
                doNotEnforceOnCreate: parameters?.doNotEnforceOnCreate
            ))
        default: .other(type)
        }
    }
}

struct RequiredCheckPayload: Decodable {
    let context: String
    let integrationId: Int?
}

/// 例外にした者（数だけを使う）
struct BypassActorPayload: Decodable {}

/// ルールセットを作る・置き換える要求の本文（REST は snake_case。PR 必須の規則は、承認 0・マージの方式は 3 つとも許す）
struct RulesetBody: Encodable, Sendable {
    struct Rule: Encodable, Sendable {
        let type: String
        let parameters: JSONValue?
    }

    let name: String
    let target = "branch"
    let enforcement = "active"
    let bypassActors: [String] = []
    let conditions: ConditionsBody
    let rules: [Rule]

    enum CodingKeys: String, CodingKey {
        case name, target, enforcement, conditions, rules
        case bypassActors = "bypass_actors"
    }

    init(_ draft: RulesetDraft) {
        name = draft.name
        conditions = ConditionsBody(refName: RefNameBody(include: draft.includes, exclude: []))
        let checks: [JSONValue] = draft.requiredChecks.map { check in
            var fields: [String: JSONValue] = ["context": .string(check)]
            if let id = draft.checksIntegrationID { fields["integration_id"] = .integer(Int64(id)) }
            return .object(fields)
        }
        rules = [
            Rule(type: "deletion", parameters: nil),
            Rule(type: "non_fast_forward", parameters: nil),
            Rule(type: "pull_request", parameters: .object([
                "required_approving_review_count": .integer(0),
                "dismiss_stale_reviews_on_push": .bool(false),
                "require_code_owner_review": .bool(false),
                "require_last_push_approval": .bool(false),
                "required_review_thread_resolution": .bool(false)
            ])),
            Rule(type: "required_status_checks", parameters: .object([
                "strict_required_status_checks_policy": .bool(false),
                // release/** のブランチを作るとき（作った直後はチェックが無い）に止めない
                "do_not_enforce_on_create": .bool(true),
                "required_status_checks": .array(checks)
            ]))
        ]
    }
}

struct RefNameBody: Encodable, Sendable {
    let include: [String]
    let exclude: [String]
}

struct ConditionsBody: Encodable, Sendable {
    let refName: RefNameBody

    enum CodingKeys: String, CodingKey {
        case refName = "ref_name"
    }
}
