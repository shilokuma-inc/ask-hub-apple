import Foundation

/// 配信の後作業（`docs/renewal/release.md` の「配信の検知と後作業」）に使う GitHub の操作。
/// どれも、作る前にあるかを確かめられるようにし、作った後に記録する前に落ちても二重に作らない
extension GitHubPullRequests {
    // MARK: - Actions の実行

    /// 作られた時刻が `from`〜`to` の Actions の実行を、ページングを最後まで追って読む（配信したビルドを上げた Upload の実行を探すのに使う）
    public func workflowRuns(createdFrom from: Date, to: Date) async throws(PullRequestError) -> [ActionsRun] {
        guard from <= to else { throw .invalidArgument("範囲の始まりが終わりより後") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let range = "\(formatter.string(from: from))..\(formatter.string(from: to))"
        let query = [URLQueryItem(name: "created", value: range), URLQueryItem(name: "per_page", value: "100")]
        let pages = try await api.pages("actions/runs", query: query, as: ActionsRunsPage.self)
        return pages.flatMap(\.workflowRuns).compactMap(\.model)
    }

    // MARK: - タグ

    /// タグが指すコミット（注釈付きのタグは、タグのオブジェクトからコミットまでたどる）。タグが無ければ nil
    public func tagCommit(_ name: String) async throws(PullRequestError) -> String? {
        try GitNames.checkTag(name)
        let ref: RefPayload
        do throws(PullRequestError) {
            ref = try await api.get("git/ref/tags/\(name)", as: RefPayload.self)
        } catch .notFound {
            return nil
        }
        switch ref.object.type {
        case "commit":
            return ref.object.sha
        case "tag":
            try GitNames.checkSHA(ref.object.sha)
            let tag = try await api.get("git/tags/\(ref.object.sha)", as: TagPayload.self)
            guard tag.object.type == "commit" else { throw .malformed("タグ \(name) がコミットを指していない（\(tag.object.type)）") }
            return tag.object.sha
        default:
            throw .malformed("タグ \(name) の ref の形が違う（\(ref.object.type ?? "なし")）")
        }
    }

    /// 注釈付きのタグを作る。同じ名前のタグがすでに同じコミットを指していれば、作らずに成功にする（前の試行が作った後に落ちたとき）。
    /// ほかのコミットを指していれば `rejected`（人が手で付けたものを動かさない）
    public func createAnnotatedTag(
        _ name: String,
        commit: String,
        message: String,
        tagger: GitIdentity,
        date: Date
    ) async throws(PullRequestError) {
        try GitNames.checkTag(name)
        try GitNames.checkSHA(commit)
        if let existing = try await tagCommit(name) {
            guard existing == commit else { throw .rejected(message: "タグ \(name) がほかのコミットを指している") }
            return
        }
        let person = CommitPerson(name: tagger.name, email: tagger.email, date: date)
        let body = TagBody(tag: name, message: message, object: commit, type: "commit", tagger: person)
        let (data, _) = try await api.send("POST", api.url("git/tags"), body: body)
        let object = try GitHubAPI.decode(ShaPayload.self, from: data, what: "git/tags")
        try GitNames.checkSHA(object.sha)
        do throws(PullRequestError) {
            _ = try await api.send("POST", api.url("git/refs"), body: RefBody(ref: "refs/tags/\(name)", sha: object.sha))
        } catch .rejected {
            // 読んだ後に、ほかの試行が同じ名前の ref を先に作った（422 の "Reference already exists"）
            guard try await tagCommit(name) == commit else { throw .rejected(message: "タグ \(name) がほかのコミットを指している") }
        }
    }

    // MARK: - GitHub Release

    /// タグの GitHub Release（下書きは含まない）。無ければ nil
    public func release(tag: String) async throws(PullRequestError) -> PublishedRelease? {
        try GitNames.checkTag(tag)
        do throws(PullRequestError) {
            return try await api.get("releases/tags/\(tag)", as: ReleasePayload.self).model
        } catch .notFound {
            return nil
        }
    }

    /// タグの GitHub Release を公開する（名前はタグと同じ。Latest にする）。すでにあれば、作らずにそれを返す
    public func publishRelease(tag: String, body: String) async throws(PullRequestError) -> PublishedRelease {
        try GitNames.checkTag(tag)
        if let existing = try await release(tag: tag) { return existing }
        let request = ReleaseBody(tagName: tag, name: tag, body: body, draft: false, prerelease: false, makeLatest: "true")
        do throws(PullRequestError) {
            let (data, _) = try await api.send("POST", api.url("releases"), body: request)
            return try GitHubAPI.decode(ReleasePayload.self, from: data, what: "releases").model
        } catch .rejected(let message) {
            // 読んだ後に、ほかの試行が同じタグの Release を先に作った
            if let existing = try await release(tag: tag) { return existing }
            throw .rejected(message: message)
        }
    }

    // MARK: - ファイルを書き換えるコミット

    /// `base` のコミットの tree に `files`（パス → 中身）を書いたコミットを作り、新しいブランチ `branch` をそこに向ける（`FileCommit`）。
    /// ブランチがすでにあれば、作らずに今の先頭を返す（前の試行が作った後に落ちたとき）。作ったコミットか、ブランチの今の先頭を返す
    public func commitFiles(_ request: FileCommit) async throws(PullRequestError) -> String {
        try GitNames.checkBranch(request.branch)
        try GitNames.checkSHA(request.base)
        try GitNames.checkSHA(request.baseTree)
        guard !request.files.isEmpty else { throw .invalidArgument("書き換えるファイルが無い") }
        if let head = try await branchHead(request.branch) { return head }
        let entries = request.files.sorted { $0.key < $1.key }.map { file in
            TreeBody.Entry(path: file.key, mode: "100644", type: "blob", content: file.value)
        }
        let (treeData, _) = try await api.send("POST", api.url("git/trees"), body: TreeBody(baseTree: request.baseTree, tree: entries))
        let tree = try GitHubAPI.decode(ShaPayload.self, from: treeData, what: "git/trees")
        try GitNames.checkSHA(tree.sha)
        let person = CommitPerson(name: request.author.name, email: request.author.email, date: request.date)
        let (commitData, _) = try await api.send(
            "POST",
            api.url("git/commits"),
            body: CommitBody(message: request.message, tree: tree.sha, parents: [request.base], author: person, committer: person)
        )
        let commit = try GitHubAPI.decode(ShaPayload.self, from: commitData, what: "git/commits")
        try GitNames.checkSHA(commit.sha)
        do throws(PullRequestError) {
            _ = try await api.send("POST", api.url("git/refs"), body: RefBody(ref: "refs/heads/\(request.branch)", sha: commit.sha))
            return commit.sha
        } catch .rejected(let message) {
            if let head = try await branchHead(request.branch) { return head }
            throw .rejected(message: message)
        }
    }
}

/// 書き手（コミットの author と committer・タグの tagger）
public struct GitIdentity: Sendable, Equatable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// `commitFiles` で作るコミット
public struct FileCommit: Sendable, Equatable {
    /// パス → 中身
    public var files: [String: String]
    /// 親にするコミットと、その tree
    public var base: String
    public var baseTree: String
    public var message: String
    public var author: GitIdentity
    public var date: Date
    /// 作るブランチ
    public var branch: String

    public init(files: [String: String], base: String, baseTree: String, message: String, author: GitIdentity, date: Date, branch: String) {
        self.files = files
        self.base = base
        self.baseTree = baseTree
        self.message = message
        self.author = author
        self.date = date
        self.branch = branch
    }
}

/// GitHub Actions の実行（配信したビルドを上げた Upload の実行を探すのに使う）
public struct ActionsRun: Sendable, Equatable {
    public var id: Int
    /// ワークフローの中の実行の番号（`run_number`。Re-run でも変わらない）
    public var runNumber: Int
    /// ワークフローのファイルのパス（`.github/workflows/upload.yml`）
    public var path: String
    public var headSHA: String
    public var event: String
    /// 最後の試行が始まった時刻（無ければ作られた時刻）
    public var startedAt: Date
    /// 最後に変わった時刻（終わった実行なら、ほぼ終わった時刻）
    public var updatedAt: Date

    public init(id: Int, runNumber: Int, path: String, headSHA: String, event: String, startedAt: Date, updatedAt: Date) {
        self.id = id
        self.runNumber = runNumber
        self.path = path
        self.headSHA = headSHA
        self.event = event
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

/// 公開した GitHub Release
public struct PublishedRelease: Sendable, Equatable {
    public var url: URL
    public var tag: String

    public init(url: URL, tag: String) {
        self.url = url
        self.tag = tag
    }
}

extension GitNames {
    /// タグの名前: ブランチ名と同じ形で、`/` を含まない（`v1.0.0` など）
    static func checkTag(_ name: String) throws(PullRequestError) {
        try checkBranch(name)
        guard !name.contains("/") else { throw .invalidArgument("タグの名前の形が違う") }
    }
}

// MARK: - 要求と応答の形（キーは `convertFromSnakeCase` で読む）

private struct ActionsRunsPage: Decodable {
    struct Run: Decodable {
        let id: Int
        let runNumber: Int?
        let path: String?
        let headSha: String?
        let event: String?
        let createdAt: String?
        let runStartedAt: String?
        let updatedAt: String?

        /// 読めない実行（欄が欠けている）は飛ばす
        var model: ActionsRun? {
            guard let runNumber, let path, let headSha, let started = (runStartedAt ?? createdAt).flatMap(GitHubDate.parse),
                  let updated = updatedAt.flatMap(GitHubDate.parse) else { return nil }
            return ActionsRun(
                id: id, runNumber: runNumber, path: path, headSHA: headSha, event: event ?? "", startedAt: started, updatedAt: updated
            )
        }
    }

    let workflowRuns: [Run]
}

private struct TagPayload: Decodable {
    struct Object: Decodable {
        let sha: String
        let type: String
    }

    let object: Object
}

private struct ShaPayload: Decodable {
    let sha: String
}

private struct ReleasePayload: Decodable {
    let htmlUrl: URL
    let tagName: String

    var model: PublishedRelease { PublishedRelease(url: htmlUrl, tag: tagName) }
}

private struct TagBody: Encodable, Sendable {
    let tag: String
    let message: String
    let object: String
    let type: String
    let tagger: CommitPerson
}

private struct RefBody: Encodable, Sendable {
    let ref: String
    let sha: String
}

private struct ReleaseBody: Encodable, Sendable {
    let tagName: String
    let name: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let makeLatest: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease
        case makeLatest = "make_latest"
    }
}

private struct TreeBody: Encodable, Sendable {
    struct Entry: Encodable, Sendable {
        let path: String
        let mode: String
        let type: String
        let content: String
    }

    let baseTree: String
    let tree: [Entry]

    enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }
}

/// Git Data API の書き手（時刻は秒までの ISO 8601）
private struct CommitPerson: Encodable, Sendable {
    let name: String
    let email: String
    let date: Date

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(email, forKey: .email)
        try container.encode(GitHubDate.format(date), forKey: .date)
    }

    enum CodingKeys: String, CodingKey {
        case name, email, date
    }
}

private struct CommitBody: Encodable, Sendable {
    let message: String
    let tree: String
    let parents: [String]
    let author: CommitPerson
    let committer: CommitPerson
}
