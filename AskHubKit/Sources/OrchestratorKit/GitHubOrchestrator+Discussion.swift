import AskHubKit
import Foundation

extension GitHubOrchestrator {
    public func comment(on discussion: ReadyDiscussion, body: String) async throws {
        let data = try await client.graphQL(
            Self.addDiscussionCommentMutation,
            variables: ["discussion": .string(discussion.nodeID), "body": .string(body)],
            as: AddDiscussionCommentData.self
        )
        // 権限不足などでは payload が null になる
        guard data.addDiscussionComment?.comment != nil else {
            throw GitHubError.invalidResponse
        }
    }

    private static let addDiscussionCommentMutation = """
        mutation($discussion: ID!, $body: String!) {
          addDiscussionComment(input: { discussionId: $discussion, body: $body }) { comment { id } }
        }
        """
}

private struct AddDiscussionCommentData: Decodable {
    struct Payload: Decodable {
        let comment: AddedDiscussionComment?
    }

    let addDiscussionComment: Payload?
}

private struct AddedDiscussionComment: Decodable {
    let id: String
}
