import AskHubProtocol
import Foundation

/// ブランチの保護（ルールセット・クラシックの保護）の読み書き（`docs/renewal/security.md` の「ブランチ保護」）。
///
/// 書く操作（作る・直す・消す）は管理用のトークン（Administration の書き込み）が要る。司令塔は、署名した人の意図（`applyProtection`）を
/// 処理するときだけ、管理用のトークンで作った `GitHubPullRequests` から呼ぶ。読む操作（ルールセットの一覧と中身）は、毎日のトークン（Metadata の読み取り）で読める
extension GitHubPullRequests {
    // MARK: - リポジトリ

    /// リポジトリの設定（既定のブランチ・公開範囲・Discussions）
    public func repositorySettings() async throws(PullRequestError) -> RepositorySettings {
        let (data, _) = try await api.send("GET", api.repositoryURL())
        return try GitHubAPI.decode(RepositorySettingsPayload.self, from: data, what: "repos").model()
    }

    // MARK: - ルールセット

    /// リポジトリに掛かっているブランチのルールセット（organization のものも含む）の一覧。中身（条件と規則）は `ruleset(id:)` で読む
    public func branchRulesets() async throws(PullRequestError) -> [RulesetSummary] {
        let query = [URLQueryItem(name: "includes_parents", value: "true"), URLQueryItem(name: "per_page", value: "100")]
        let pages = try await api.pages("rulesets", query: query, as: [RulesetSummaryPayload].self)
        return pages.joined().filter { $0.target == "branch" }.map { $0.model() }
    }

    /// ルールセットの中身
    public func ruleset(id: Int) async throws(PullRequestError) -> Ruleset {
        try GitNames.checkNumber(id)
        return try await api.get("rulesets/\(id)", as: RulesetPayload.self).model()
    }

    /// ルールセットを作る（`id` が nil）か、置き換える。作った・置き換えた後の中身を返す
    public func putRuleset(_ ruleset: RulesetDraft, id: Int?) async throws(PullRequestError) -> Ruleset {
        let body = RulesetBody(ruleset)
        let data: Data
        if let id {
            try GitNames.checkNumber(id)
            (data, _) = try await api.send("PUT", api.url("rulesets/\(id)"), body: body)
        } else {
            (data, _) = try await api.send("POST", api.url("rulesets"), body: body)
        }
        return try GitHubAPI.decode(RulesetPayload.self, from: data, what: "rulesets").model()
    }

    /// リポジトリのルールセットを消す。もう無ければ何もしない
    public func deleteRuleset(id: Int) async throws(PullRequestError) {
        try GitNames.checkNumber(id)
        do throws(PullRequestError) {
            _ = try await api.send("DELETE", api.url("rulesets/\(id)"))
        } catch .notFound {
            return
        }
    }

    // MARK: - クラシックの保護

    /// クラシックのブランチ保護の規則（パターンごと）。読むにも Administration が要る
    public func branchProtectionRules() async throws(PullRequestError) -> [BranchProtectionRule] {
        var rules: [BranchProtectionRule] = []
        var after: String?
        repeat {
            let variables = ProtectionRulesVariables(owner: repository.owner, name: repository.name, after: after)
            let response = try await api.graphQL(Self.protectionRulesQuery, variables: variables, as: ProtectionRulesData.self)
            guard let connection = response.repository?.branchProtectionRules else { throw .notFound }
            rules += connection.nodes.compactMap { $0.map { BranchProtectionRule(id: $0.id, pattern: $0.pattern) } }
            after = connection.pageInfo.hasNextPage ? connection.pageInfo.endCursor : nil
            guard rules.count <= 100 * GitHubAPI.maxPages else { throw .malformed("branchProtectionRules が多すぎる") }
        } while after != nil
        return rules
    }

    /// クラシックのブランチ保護の規則を消す
    public func deleteBranchProtectionRule(id: String) async throws(PullRequestError) {
        guard !id.isEmpty, id.utf8.count <= 200 else { throw .invalidArgument("branchProtectionRule の id の形が違う") }
        _ = try await api.graphQL(Self.deleteProtectionRuleMutation, variables: ["id": id], as: DeleteProtectionRuleData.self)
    }

    static let protectionRulesQuery = """
        query($owner: String!, $name: String!, $after: String) {
          repository(owner: $owner, name: $name) {
            branchProtectionRules(first: 100, after: $after) {
              nodes { id pattern }
              pageInfo { hasNextPage endCursor }
            }
          }
        }
        """

    static let deleteProtectionRuleMutation = """
        mutation($id: ID!) {
          deleteBranchProtectionRule(input: { branchProtectionRuleId: $id }) { clientMutationId }
        }
        """
}

// MARK: - GraphQL の形

private struct ProtectionRulesVariables: Encodable, Sendable {
    let owner: String
    let name: String
    let after: String?
}

private struct ProtectionRulesData: Decodable {
    struct Repository: Decodable {
        let branchProtectionRules: ProtectionRulesConnection
    }

    let repository: Repository?
}

private struct ProtectionRulesConnection: Decodable {
    struct Node: Decodable {
        let id: String
        let pattern: String
    }

    let nodes: [Node?]
    let pageInfo: ProtectionRulesPageInfo
}

private struct ProtectionRulesPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

private struct DeleteProtectionRuleData: Decodable {}
