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

    public func discussionSettings(in repository: String) async throws -> DiscussionSettings {
        let parts = repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        let data = try await client.graphQL(
            Self.discussionSettingsQuery,
            variables: ["owner": .string(parts[0]), "name": .string(parts[1])],
            as: DiscussionSettingsData.self
        )
        guard let repository = data.repository else {
            throw GitHubError.invalidResponse
        }
        return DiscussionSettings(
            isEnabled: repository.hasDiscussionsEnabled,
            categories: repository.discussionCategories.nodes.compactMap { $0?.name }
        )
    }

    public func enableDiscussions(in repository: String) async throws {
        // Discussions を有効にすると、GitHub が既定のカテゴリ（Ideas など）を作る
        try await client.send("PATCH", "repos/\(repository)", body: ["has_discussions": true])
    }

    // カテゴリは 1 つのリポジトリに 25 個までしか作れないので、ページングしない
    private static let discussionSettingsQuery = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            hasDiscussionsEnabled
            discussionCategories(first: 100) { nodes { name } }
          }
        }
        """
}

private struct DiscussionSettingsData: Decodable {
    struct Repository: Decodable {
        let hasDiscussionsEnabled: Bool
        let discussionCategories: DiscussionCategoryNodes
    }

    let repository: Repository?
}

private struct DiscussionCategoryNodes: Decodable {
    struct Category: Decodable {
        let name: String
    }

    let nodes: [Category?]
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
