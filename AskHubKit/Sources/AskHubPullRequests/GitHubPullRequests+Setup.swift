import AskHubProtocol
import Foundation

/// 対象に加えるときの GitHub 側の準備（Discussions・ワークフローのファイル）の操作。
///
/// 書く操作（Discussions を有効にする・ワークフローのファイルを変えるコミット）は管理用のトークン（Administration・Workflows の書き込み）が要る。
/// 司令塔は、署名した人の意図（`addRepository`・`approveSetupPullRequest`）を処理するときだけ、管理用のトークンで作った `GitHubPullRequests` から呼ぶ
extension GitHubPullRequests {
    /// Discussions を有効にする
    public func enableDiscussions() async throws(PullRequestError) {
        _ = try await api.send("PATCH", api.repositoryURL(), body: DiscussionsBody(hasDiscussions: true))
    }

    /// Discussion のカテゴリの名前
    public func discussionCategoryNames() async throws(PullRequestError) -> [String] {
        let variables = RepositoryVariables(owner: repository.owner, name: repository.name)
        let response = try await api.graphQL(Self.categoriesQuery, variables: variables, as: CategoriesData.self)
        guard let repository = response.repository else { throw .notFound }
        return repository.discussionCategories.nodes.compactMap { $0?.name }
    }

    /// `ref` の `.github/workflows/` の YAML のファイル（パスと中身）。フォルダが無ければ空
    public func workflowFiles(ref: String) async throws(PullRequestError) -> [WorkflowFile] {
        try GitNames.checkBranch(ref)
        let entries: [ContentEntry]
        do throws(PullRequestError) {
            let query = [URLQueryItem(name: "ref", value: ref)]
            entries = try await api.get("contents/.github/workflows", query: query, as: [ContentEntry].self)
        } catch .notFound {
            return []
        }
        var files: [WorkflowFile] = []
        for entry in entries where entry.type == "file" && (entry.name.hasSuffix(".yml") || entry.name.hasSuffix(".yaml")) {
            try GitNames.checkSHA(entry.sha)
            let blob = try await api.get("git/blobs/\(entry.sha)", as: BlobPayload.self)
            let compact = blob.content.filter { !$0.isWhitespace }
            guard blob.encoding == "base64", let data = Data(base64Encoded: compact), let text = String(bytes: data, encoding: .utf8) else {
                throw .malformed("\(entry.path) の中身を読めない")
            }
            files.append(WorkflowFile(path: entry.path, text: text))
        }
        return files
    }

    /// `base` のコミットの上に、ファイルを書き換え（中身）・消す（nil）コミットを作り、ブランチ `branch` を向ける（無ければ作り、あれば向け直す）。
    /// 作ったコミットを返す。書き手は、トークンのアカウント（GitHub が決める）
    public func commitChanges(
        _ changes: [String: String?],
        onto base: String,
        branch: String,
        message: String
    ) async throws(PullRequestError) -> String {
        try GitNames.checkBranch(branch)
        try GitNames.checkSHA(base)
        guard !changes.isEmpty else { throw .invalidArgument("書き換えるファイルが無い") }
        let parent = try await api.get("git/commits/\(base)", as: CommitTreePayload.self)
        try GitNames.checkSHA(parent.tree.sha)
        let entries = changes.sorted { $0.key < $1.key }.map { SetupTreeEntry(path: $0.key, content: $0.value) }
        let (treeData, _) = try await api.send("POST", api.url("git/trees"), body: SetupTreeBody(baseTree: parent.tree.sha, tree: entries))
        let tree = try GitHubAPI.decode(SetupShaPayload.self, from: treeData, what: "git/trees")
        try GitNames.checkSHA(tree.sha)
        let (commitData, _) = try await api.send(
            "POST", api.url("git/commits"), body: SetupCommitBody(message: message, tree: tree.sha, parents: [base])
        )
        let commit = try GitHubAPI.decode(SetupShaPayload.self, from: commitData, what: "git/commits")
        try GitNames.checkSHA(commit.sha)
        if try await branchHead(branch) != nil {
            _ = try await api.send("PATCH", api.url("git/refs/heads/\(branch)"), body: SetupRefUpdate(sha: commit.sha, force: true))
        } else {
            _ = try await api.send("POST", api.url("git/refs"), body: SetupRefBody(ref: "refs/heads/\(branch)", sha: commit.sha))
        }
        return commit.sha
    }

    static let categoriesQuery = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            discussionCategories(first: 100) { nodes { name } }
          }
        }
        """
}

/// ワークフローのファイル
public struct WorkflowFile: Equatable, Sendable {
    /// リポジトリの直下からのパス（`.github/workflows/build.yml`）
    public var path: String
    public var text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }

    /// ファイルの名前（`build.yml`）
    public var name: String {
        String(path.split(separator: "/").last ?? "")
    }
}

// MARK: - 要求と応答の形

private struct DiscussionsBody: Encodable, Sendable {
    let hasDiscussions: Bool

    enum CodingKeys: String, CodingKey {
        case hasDiscussions = "has_discussions"
    }
}

private struct RepositoryVariables: Encodable, Sendable {
    let owner: String
    let name: String
}

private struct CategoriesData: Decodable {
    struct Repository: Decodable {
        let discussionCategories: CategoryNodes
    }

    let repository: Repository?
}

private struct CategoryNodes: Decodable {
    struct Node: Decodable {
        let name: String
    }

    let nodes: [Node?]
}

private struct ContentEntry: Decodable {
    let name: String
    let path: String
    let sha: String
    let type: String
}

private struct BlobPayload: Decodable {
    let content: String
    let encoding: String
}

private struct CommitTreePayload: Decodable {
    struct Tree: Decodable {
        let sha: String
    }

    let tree: Tree
}

private struct SetupShaPayload: Decodable {
    let sha: String
}

/// tree の 1 つ。中身が nil なら、そのパスを消す（`sha` を null にして送る）
private struct SetupTreeEntry: Encodable, Sendable {
    let path: String
    let content: String?

    enum CodingKeys: String, CodingKey {
        case path, mode, type, content, sha
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode("100644", forKey: .mode)
        try container.encode("blob", forKey: .type)
        if let content {
            try container.encode(content, forKey: .content)
        } else {
            try container.encodeNil(forKey: .sha)
        }
    }
}

private struct SetupTreeBody: Encodable, Sendable {
    let baseTree: String
    let tree: [SetupTreeEntry]

    enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }
}

private struct SetupCommitBody: Encodable, Sendable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct SetupRefBody: Encodable, Sendable {
    let ref: String
    let sha: String
}

private struct SetupRefUpdate: Encodable, Sendable {
    let sha: String
    let force: Bool
}
