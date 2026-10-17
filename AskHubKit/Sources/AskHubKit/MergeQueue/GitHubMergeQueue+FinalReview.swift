import Foundation

/// 最終 PR のコメントから、第三者レビューと進み具合の目印を読む（Discussion #503）
extension GitHubMergeQueue {
    /// 検索で取れた最初のページより後ろの PR のコメントを、最後まで取る
    func remainingComments(of pullRequest: EpicPullRequest, after cursor: String) async throws -> [PullRequestCommentNode] {
        let parts = pullRequest.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        return try await collectGraphQLPages { after in
            let data = try await client.graphQL(
                Self.commentsQuery,
                variables: [
                    "owner": .string(parts[0]), "name": .string(parts[1]), "number": .int(pullRequest.number),
                    "after": .string(after ?? cursor)
                ],
                as: CommentsData.self
            )
            guard let comments = data.repository?.pullRequest?.comments else {
                return ([], GraphQLPageInfo(hasNextPage: false, endCursor: nil))
            }
            return (comments.nodes.compactMap(\.self), comments.pageInfo)
        }
    }

    /// 信用する author が書いたコメントのうち、今の head（`headSHA`）に対する最新の第三者レビューの目印と進み具合の目印を付ける。
    /// public リポジトリでは誰でも目印を書けるので、信用しない author のコメントは読まない。`sha` が今の head と違う目印（前の head のもの）は使わない
    static func attachFinalReview(
        to pullRequest: inout EpicPullRequest,
        comments: [PullRequestCommentNode],
        trustedAuthors: TrustedAuthors
    ) {
        let head = pullRequest.headSHA.lowercased()
        let bodies = comments.filter { trustedAuthors.contains($0.author?.login) }.compactMap(\.body)
        pullRequest.thirdPartyReview = bodies.compactMap(ThirdPartyReviewMarker.parse).last { $0.sha == head }
        pullRequest.finalReview = bodies.compactMap(FinalReviewMarker.parse).last { $0.sha == head }
    }

    /// 1 ページ目に収まらなかった PR のコメントを取り直す
    static let commentsQuery = """
        query($owner: String!, $name: String!, $number: Int!, $after: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { comments(first: 100, after: $after) { ...Comments } }
          }
        }
        \(commentsFragment)
        """

    /// PR の会話のコメント（第三者レビューと進み具合の目印を読む）
    static let commentsFragment = """
        fragment Comments on IssueCommentConnection {
          pageInfo { hasNextPage endCursor }
          nodes { author { login } body }
        }
        """
}

/// PR の会話のコメント（ページングされる connection）
struct PullRequestComments: Decodable {
    let pageInfo: GraphQLPageInfo
    let nodes: [PullRequestCommentNode?]
}

/// PR の会話のコメント 1 件。削除済みのユーザーでは `author` が `null`
struct PullRequestCommentNode: Decodable {
    struct Login: Decodable {
        let login: String
    }

    let author: Login?
    let body: String?
}

private struct CommentsData: Decodable {
    struct Repository: Decodable {
        let pullRequest: CommentsPullRequest?
    }

    let repository: Repository?
}

private struct CommentsPullRequest: Decodable {
    let comments: PullRequestComments?
}
