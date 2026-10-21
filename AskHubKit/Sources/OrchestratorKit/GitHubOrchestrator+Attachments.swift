import AskHubKit
import Foundation

/// 依頼の添付の取得と、作った Discussion への添付欄の引き継ぎ（Discussion #669）
extension GitHubOrchestrator {
    public func attachmentContent(_ marker: AttachmentMarker, in repository: String) async throws -> Data {
        try await GitHubAttachmentFetcher(client: client).fetch(marker, from: repository)
    }

    public func appendAttachments(_ markers: [AttachmentMarker], toDiscussion number: Int, in repository: String) async throws {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            throw GitHubError.invalidResponse
        }
        let data = try await client.graphQL(
            Self.discussionBodyQuery,
            variables: ["owner": .string(parts[0]), "name": .string(parts[1]), "number": .int(number)],
            as: DiscussionBodyData.self
        )
        guard let discussion = data.repository?.discussion else {
            throw GitHubError.invalidResponse
        }
        // 前の周回で足し終えていれば、同じ目印を重ねない
        let existing = Set(AttachmentMarker.parseAll(discussion.body).map(\.path))
        let missing = markers.filter { !existing.contains($0.path) }
        guard !missing.isEmpty else {
            return
        }
        let body = AttachmentSection.appending(missing, to: discussion.body, repository: repository)
        let updated = try await client.graphQL(
            Self.updateDiscussionMutation,
            variables: ["id": .string(discussion.id), "body": .string(body)],
            as: UpdateDiscussionData.self
        )
        // 権限不足などでは payload が null になる
        guard updated.updateDiscussion?.discussion != nil else {
            throw GitHubError.invalidResponse
        }
    }

    private static let discussionBodyQuery = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) { discussion(number: $number) { id body } }
        }
        """

    private static let updateDiscussionMutation = """
        mutation($id: ID!, $body: String!) {
          updateDiscussion(input: { discussionId: $id, body: $body }) { discussion { id } }
        }
        """
}

private struct DiscussionBodyData: Decodable {
    struct Repository: Decodable {
        let discussion: Discussion?
    }

    struct Discussion: Decodable {
        let id: String
        let body: String
    }

    let repository: Repository?
}

private struct UpdateDiscussionData: Decodable {
    struct Payload: Decodable {
        let discussion: Updated?
    }

    struct Updated: Decodable {
        let id: String
    }

    let updateDiscussion: Payload?
}
