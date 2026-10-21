import AskHubKit
import Foundation

/// 最終 PR のマージ後の添付の片付け（Discussion #669 の Q7）
extension GitHubOrchestrator {
    /// 最終 PR を探す範囲（最近更新された closed な PR の件数）。マージから日が経った PR は対象にしない
    static let recentClosedPullRequests = 50

    public func mergedEpicFinalPullRequests(in repository: String) async throws -> [MergedEpicFinalPullRequest] {
        let pulls: [ClosedPullRequestSummary] = try await client.get(
            "repos/\(repository)/pulls",
            query: [
                URLQueryItem(name: "state", value: "closed"),
                URLQueryItem(name: "sort", value: "updated"),
                URLQueryItem(name: "direction", value: "desc"),
                URLQueryItem(name: "per_page", value: "\(Self.recentClosedPullRequests)")
            ]
        )
        return pulls
            .filter { $0.mergedAt != nil && $0.labels.contains { $0.name == AskHubLabel.epicFinal.rawValue } }
            .map {
                MergedEpicFinalPullRequest(
                    repository: repository,
                    number: $0.number,
                    headBranch: $0.head.ref,
                    author: $0.user?.login,
                    goalDiscussion: GoalDiscussionMarker.discussion(in: $0.body ?? "")
                )
            }
    }

    public func discussionTexts(in repository: String, number: Int) async throws -> [AuthoredText] {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        var opening: AuthoredText?
        let comments: [DiscussionCommentNode] = try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.discussionTextsQuery,
                variables: [
                    "owner": .string(parts[0]),
                    "name": .string(parts[1]),
                    "number": .int(number),
                    "after": after.map(GraphQLVariable.string) ?? .null
                ],
                as: DiscussionTextsData.self
            )
            guard let discussion = data.repository?.discussion else {
                throw GitHubError.invalidResponse
            }
            opening = AuthoredText(author: discussion.author?.login, body: discussion.body)
            return (discussion.comments.nodes.compactMap(\.self), discussion.comments.pageInfo)
        }
        var texts = opening.map { [$0] } ?? []
        for comment in comments {
            texts.append(AuthoredText(author: comment.author?.login, body: comment.body))
            // 返信は 1 つのコメントにつき 100 件まで（ループの準備と同じ。超えるものは準備が止めて知らせる）
            texts += comment.replies.nodes.compactMap(\.self).map { AuthoredText(author: $0.author?.login, body: $0.body) }
        }
        return texts
    }

    public func childPullRequestReviewComments(in repository: String, base branch: String) async throws -> [AuthoredText] {
        let pulls = try await client.getAllPages(
            "repos/\(repository)/pulls",
            query: [URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "base", value: branch)],
            of: NumberedPullRequest.self
        )
        var texts: [AuthoredText] = []
        for pull in pulls.sorted(by: { $0.number < $1.number }) {
            let comments = try await client.getAllPages("repos/\(repository)/pulls/\(pull.number)/comments", of: ReviewComment.self)
            texts += comments.map { AuthoredText(author: $0.user?.login, body: $0.body ?? "") }
        }
        return texts
    }

    public func deleteAttachments(at paths: [String], in repository: String) async throws -> Int {
        let refPath = "repos/\(repository)/git/refs/heads/\(AttachmentMarker.branch)"
        let ref: GitRefResponse
        do {
            ref = try await client.get("repos/\(repository)/git/ref/heads/\(AttachmentMarker.branch)")
        } catch GitHubError.http(status: 404, _) {
            // ブランチが無い（添付を上げたことが無い・手で消した）
            return 0
        }
        let commit: GitCommitResponse = try await client.get("repos/\(repository)/git/commits/\(ref.object.sha)")
        let tree: GitTreeResponse = try await client.get(
            "repos/\(repository)/git/trees/\(commit.tree.sha)",
            query: [URLQueryItem(name: "recursive", value: "1")]
        )
        // 今のブランチにあるファイルだけを消す（無いパスを消そうとすると tree の作成が失敗する）。
        // 一覧が途中で切れていたら、あるかどうか分からないので目印のパスをすべて消しにいく
        let existing = Set(tree.tree.filter { $0.type == "blob" }.map(\.path))
        let targets = tree.truncated == true ? paths : paths.filter { existing.contains($0) }
        guard !targets.isEmpty else {
            return 0
        }
        let newTree: GitObjectResponse = try await client.send(
            "POST",
            "repos/\(repository)/git/trees",
            body: DeletingTreeRequest(baseTree: commit.tree.sha, paths: targets)
        )
        let newCommit: GitObjectResponse = try await client.send(
            "POST",
            "repos/\(repository)/git/commits",
            body: DeletingCommitRequest(
                message: "[chore] 最終 PR のマージ後に添付を消す: \(targets.count) 件",
                tree: newTree.sha,
                parents: [ref.object.sha]
            )
        )
        do {
            // force にしない。ほかの送信が先にブランチを進めていたら 422 になるので、次のポーリングでやり直す
            try await client.send("PATCH", refPath, body: UpdateRefRequest(sha: newCommit.sha, force: false))
        } catch GitHubError.http(status: 422, _) {
            throw AttachmentCleanupError.conflict
        }
        return targets.count
    }

    private static let discussionTextsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            discussion(number: $number) {
              body author { login }
              comments(first: 100, after: $after) {
                pageInfo { hasNextPage endCursor }
                nodes { body author { login } replies(first: 100) { nodes { body author { login } } } }
              }
            }
          }
        }
        """
}

private struct Login: Decodable {
    let login: String
}

private struct ClosedPullRequestSummary: Decodable {
    struct Ref: Decodable {
        let ref: String
    }

    struct Label: Decodable {
        let name: String
    }

    let number: Int
    let body: String?
    let head: Ref
    let user: Login?
    let labels: [Label]
    let mergedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case number, body, head, user, labels
        case mergedAt = "merged_at"
    }
}

private struct DiscussionTextsData: Decodable {
    struct Repository: Decodable {
        let discussion: Discussion?
    }

    struct Discussion: Decodable {
        let body: String
        let author: Login?
        let comments: Comments
    }

    struct Comments: Decodable {
        let pageInfo: GraphQLPageInfo
        let nodes: [DiscussionCommentNode?]
    }

    let repository: Repository?
}

private struct DiscussionCommentNode: Decodable {
    struct Replies: Decodable {
        let nodes: [Reply?]
    }

    struct Reply: Decodable {
        let body: String
        let author: Login?
    }

    let body: String
    let author: Login?
    let replies: Replies
}

private struct NumberedPullRequest: Decodable {
    let number: Int
}

private struct ReviewComment: Decodable {
    let user: Login?
    let body: String?
}

private struct GitRefResponse: Decodable {
    struct Object: Decodable {
        let sha: String
    }

    let object: Object
}

private struct GitCommitResponse: Decodable {
    struct Tree: Decodable {
        let sha: String
    }

    let tree: Tree
}

private struct GitTreeResponse: Decodable {
    struct Entry: Decodable {
        let path: String
        let type: String
    }

    let tree: [Entry]
    let truncated: Bool?
}

private struct GitObjectResponse: Decodable {
    let sha: String
}

/// 消すパスを `sha: null` にした tree（`base_tree` の上に作る）
private struct DeletingTreeRequest: Encodable, Sendable {
    let baseTree: String
    let paths: [String]

    private enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseTree, forKey: .baseTree)
        try container.encode(paths.map(DeletingTreeEntry.init(path:)), forKey: .tree)
    }
}

private struct DeletingCommitRequest: Encodable, Sendable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct UpdateRefRequest: Encodable, Sendable {
    let sha: String
    let force: Bool
}

/// 消す 1 つのパス（`sha: null`）
private struct DeletingTreeEntry: Encodable {
    let path: String

    private enum CodingKeys: String, CodingKey {
        case path, mode, type, sha
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode("100644", forKey: .mode)
        try container.encode("blob", forKey: .type)
        // null を書くと、そのパスを消す（省くと消えない）
        try container.encodeNil(forKey: .sha)
    }
}
