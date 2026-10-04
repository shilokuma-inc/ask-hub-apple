import Foundation

/// 回答を投稿できないときのエラー
public enum AnswerPostingError: Error, Equatable, Sendable {
    /// 回答がその質問に合わない（選択肢を選んでいない・自由記述が空など）
    case invalidAnswer
    /// PR のレビューコメントの REST の id が無く、返信先を決められない
    case missingCommentID
}

/// 質問への回答（返信）を投稿する。テストでは差し替える
public protocol AnswerPosting: Sendable {
    /// 質問のコメントへの返信として回答を投稿し、投稿したコメントの URL を返す
    func post(_ answer: Answer, to question: InboxQuestion) async throws -> URL
}

/// GitHub に回答を投稿する（`docs/protocol.md` の「質問の場所」「回答の形式」）
public struct GitHubAnswerPoster: AnswerPosting {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func post(_ answer: Answer, to question: InboxQuestion) async throws -> URL {
        guard answer.isValid(for: question.marker) else {
            throw AnswerPostingError.invalidAnswer
        }
        switch question.subject.kind {
        case .discussion:
            // ※1: 質問のコメントへの返信（スレッド）
            let data = try await client.graphQL(
                Self.replyMutation,
                variables: [
                    "discussion": .string(question.subject.nodeID),
                    "replyTo": .string(question.comment.nodeID),
                    "body": .string(answer.body)
                ],
                as: ReplyData.self
            )
            guard let url = data.addDiscussionComment?.comment?.url else {
                throw GitHubError.invalidResponse
            }
            return url

        case .pullRequest:
            // ※2: レビューコメントへの返信（in_reply_to）
            guard let commentID = question.comment.databaseID else {
                throw AnswerPostingError.missingCommentID
            }
            let reply = try await client.send(
                "POST",
                "repos/\(question.subject.repository)/pulls/\(question.subject.number)/comments/\(commentID)/replies",
                body: ["body": answer.body],
                as: ReviewCommentReply.self
            )
            return reply.htmlURL
        }
    }

    private static let replyMutation = """
        mutation($discussion: ID!, $replyTo: ID!, $body: String!) {
          addDiscussionComment(input: { discussionId: $discussion, replyToId: $replyTo, body: $body }) {
            comment { url }
          }
        }
        """
}

private struct ReplyData: Decodable {
    struct Payload: Decodable {
        let comment: CommentURL?
    }

    let addDiscussionComment: Payload?
}

private struct CommentURL: Decodable {
    let url: URL
}

private struct ReviewCommentReply: Decodable {
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
    }
}
