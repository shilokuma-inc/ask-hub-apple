import AskHubProtocol
import AskHubStateStore
import Foundation

/// テンプレートからリポジトリを作り、作った直後にアプリ名を書き換える操作（`docs/renewal/operations.md` の「テンプレートからの新規作成」）。
///
/// どれも管理用のトークン（その持ち主の All repositories の Administration・Contents・Workflows の書き込み）が要る。
/// 司令塔は、署名した人の意図（`createRepository`）を処理するときだけ、作るリポジトリの持ち主の管理用のトークンで作った `GitHubPullRequests` から呼ぶ
extension GitHubPullRequests {
    /// このリポジトリ（これから作るもの）の様子。まだ無ければ nil
    public func existingRepository() async throws(PullRequestError) -> ExistingRepository? {
        do throws(PullRequestError) {
            let (data, _) = try await api.send("GET", api.repositoryURL())
            return try GitHubAPI.decode(ExistingRepositoryPayload.self, from: data, what: "repos").model
        } catch .notFound {
            return nil
        }
    }

    /// `template` から、このリポジトリを作る（既定のブランチだけを写す）。作るのは GitHub の側で少し遅れて終わる（ブランチが後から出る）
    public func generate(from template: RepositoryFullName, isPrivate: Bool) async throws(PullRequestError) {
        let body = GenerateBody(owner: repository.owner, name: repository.name, private: isPrivate, includeAllBranches: false)
        _ = try await api.send("POST", api.rootURL("repos/\(template.owner)/\(template.name)/generate"), body: body)
    }

    /// コミットのファイルの一覧（tree を再帰で読む。サブモジュール・シンボリックリンクも 1 つとして含む）。GitHub が途中で切ったら断る
    public func files(at commit: String) async throws(PullRequestError) -> [TreeFile] {
        try GitNames.checkSHA(commit)
        let tree = try await api.get("git/trees/\(commit)", query: [.init(name: "recursive", value: "1")], as: TreePayload.self)
        guard !tree.truncated else { throw .malformed("ファイルが多すぎて tree を読み切れない") }
        return try tree.tree.filter { $0.type != "tree" }.map { entry throws(PullRequestError) in
            try GitNames.checkSHA(entry.sha)
            return TreeFile(path: entry.path, mode: entry.mode, type: entry.type, sha: entry.sha)
        }
    }

    /// blob の中身（UTF-8 のテキスト）。バイナリ・UTF-8 で読めないものは nil。GraphQL でまとめて読み、途中で切られた大きなものだけ REST で読み直す
    public func blobTexts(_ shas: [String]) async throws(PullRequestError) -> [String: String?] {
        var texts: [String: String?] = [:]
        let unique = Array(Set(shas)).sorted()
        for start in stride(from: 0, to: unique.count, by: Self.blobBatch) {
            let batch = Array(unique[start..<min(start + Self.blobBatch, unique.count)])
            for sha in batch { try GitNames.checkSHA(sha) }
            let fields = batch.enumerated().map { index, sha in
                "b\(index): object(oid: \"\(sha)\") { ... on Blob { text isBinary isTruncated } }"
            }
            let query = "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { "
                + fields.joined(separator: " ") + " } }"
            let variables = TemplateRepositoryVariables(owner: repository.owner, name: repository.name)
            let response = try await api.graphQL(query, variables: variables, as: BlobTextsData.self)
            guard let nodes = response.repository else { throw .notFound }
            for (index, sha) in batch.enumerated() {
                guard let node = nodes["b\(index)"].flatMap({ $0 }) else { throw .malformed("blob \(sha) が無い") }
                if node.isBinary == true {
                    texts[sha] = .some(nil)
                } else if node.isTruncated == true || node.text == nil {
                    texts[sha] = .some(try await restBlobText(sha))
                } else {
                    texts[sha] = .some(node.text)
                }
            }
        }
        return texts
    }

    /// ファイルの一覧（`files` を書き換えたもの）から tree を作り、`parent` の上のコミットにして、`branch` を進める（force でない。
    /// 読んだ後に進んでいたら GitHub が断る）。中身（`content`）を持つものは新しい blob、持たないものは `sha` の blob を使う。作ったコミットを返す
    public func commitFiles(_ files: [TreeFile], parent: String, branch: String, message: String) async throws(PullRequestError) -> String {
        try GitNames.checkBranch(branch)
        try GitNames.checkSHA(parent)
        guard !files.isEmpty else { throw .invalidArgument("ファイルが無い") }
        let entries = files.map(TemplateTreeEntry.init)
        let (treeData, _) = try await api.send("POST", api.url("git/trees"), body: TemplateTreeBody(tree: entries))
        let tree = try GitHubAPI.decode(TemplateShaPayload.self, from: treeData, what: "git/trees")
        try GitNames.checkSHA(tree.sha)
        let (commitData, _) = try await api.send(
            "POST", api.url("git/commits"), body: TemplateCommitBody(message: message, tree: tree.sha, parents: [parent])
        )
        let commit = try GitHubAPI.decode(TemplateShaPayload.self, from: commitData, what: "git/commits")
        try GitNames.checkSHA(commit.sha)
        _ = try await api.send("PATCH", api.url("git/refs/heads/\(branch)"), body: TemplateRefUpdate(sha: commit.sha, force: false))
        return commit.sha
    }

    /// 1 回の GraphQL で読む blob の数
    static let blobBatch = 50

    private func restBlobText(_ sha: String) async throws(PullRequestError) -> String? {
        let blob = try await api.get("git/blobs/\(sha)", as: TemplateBlobPayload.self)
        guard blob.encoding == "base64", let data = Data(base64Encoded: blob.content.filter { !$0.isWhitespace }) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 作る前に、同じ名前のリポジトリがあったときの様子
public struct ExistingRepository: Equatable, Sendable {
    /// テンプレートから作ったなら、元のテンプレート（`owner/name`）
    public var template: String?
    public var isPrivate: Bool
    public var defaultBranch: String

    public init(template: String?, isPrivate: Bool, defaultBranch: String) {
        self.template = template
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
    }
}

/// tree の 1 つ（ファイル・シンボリックリンク・サブモジュール）。`content` があれば、その中身の新しい blob にする
public struct TreeFile: Equatable, Sendable {
    public var path: String
    /// `100644`・`100755`・`120000`（シンボリックリンク）・`160000`（サブモジュール）
    public var mode: String
    /// `blob`・`commit`（サブモジュール）
    public var type: String
    public var sha: String
    /// 書き換えた中身。変えないなら nil（`sha` をそのまま使う）
    public var content: String?

    public init(path: String, mode: String, type: String, sha: String, content: String? = nil) {
        self.path = path
        self.mode = mode
        self.type = type
        self.sha = sha
        self.content = content
    }
}

// MARK: - 要求と応答の形

private struct ExistingRepositoryPayload: Decodable {
    struct Template: Decodable {
        let fullName: String
    }

    let templateRepository: Template?
    let `private`: Bool
    let defaultBranch: String

    var model: ExistingRepository {
        ExistingRepository(template: templateRepository?.fullName, isPrivate: `private`, defaultBranch: defaultBranch)
    }
}

private struct GenerateBody: Encodable, Sendable {
    let owner: String
    let name: String
    let `private`: Bool
    let includeAllBranches: Bool

    enum CodingKeys: String, CodingKey {
        case owner, name, `private`
        case includeAllBranches = "include_all_branches"
    }
}

private struct TreePayload: Decodable {
    struct Entry: Decodable {
        let path: String
        let mode: String
        let type: String
        let sha: String
    }

    let tree: [Entry]
    let truncated: Bool
}

private struct TemplateRepositoryVariables: Encodable, Sendable {
    let owner: String
    let name: String
}

private struct BlobTextsData: Decodable {
    struct Node: Decodable {
        let text: String?
        let isBinary: Bool?
        let isTruncated: Bool?
    }

    let repository: [String: Node?]?
}

private struct TemplateBlobPayload: Decodable {
    let content: String
    let encoding: String
}

/// tree の 1 つ。中身があれば `content`、無ければ `sha` を送る（base の tree は使わず、全部のファイルを並べる）
private struct TemplateTreeEntry: Encodable, Sendable {
    let path: String
    let mode: String
    let type: String
    let sha: String?
    let content: String?

    init(_ file: TreeFile) {
        path = file.path
        mode = file.mode
        type = file.type
        sha = file.content == nil ? file.sha : nil
        content = file.content
    }

    enum CodingKeys: String, CodingKey {
        case path, mode, type, sha, content
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(mode, forKey: .mode)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(sha, forKey: .sha)
        try container.encodeIfPresent(content, forKey: .content)
    }
}

private struct TemplateTreeBody: Encodable, Sendable {
    let tree: [TemplateTreeEntry]
}

private struct TemplateCommitBody: Encodable, Sendable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct TemplateShaPayload: Decodable {
    let sha: String
}

private struct TemplateRefUpdate: Encodable, Sendable {
    let sha: String
    let force: Bool
}
