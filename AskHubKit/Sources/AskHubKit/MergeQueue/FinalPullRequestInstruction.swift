import Foundation

/// 最終 PR に投稿する、CodeRabbit の指摘 1 件を直させる指示（`docs/protocol.md` の「最終 PR への指示」の「指示の形式」）。
/// アプリの「マージ待ち」の「ループに直させる」が投稿する。押すことが人間の承認になる（Discussion #498 の案 4）
public enum FinalPullRequestInstruction {
    /// 指示のコメントの本文。1 行目に指摘のリンク、2 行目以降に補足（任意）。
    /// 補足がほかの指摘を指す・目印で始まるなど、1 件の指摘を指す指示にならないときは `nil`（Q2: 指摘は 1 件ずつ指す）
    public static func body(for thread: CodeRabbitReviewThread, note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = "\(thread.finding.url.absoluteString) を直して"
        let body = trimmed.isEmpty ? firstLine : "\(firstLine)\n\(trimmed)"
        guard FinalPullRequestHistory.referencedReviewComments(in: body) == [thread.finding.id] else {
            return nil
        }
        // 目印で始まると、ループの返信・オーケストレーターのコメントとみなされて指示にならない
        let markers = [FinalPullRequestMarker.reply, FinalPullRequestMarker.orchestrator]
        guard !markers.contains(where: { body.contains($0) }) else {
            return nil
        }
        return body
    }
}

/// 指示を投稿できないときのエラー
public enum FinalPullRequestInstructionError: Error, Equatable, Sendable {
    /// 指示が 1 件の指摘を指す形にならない（`FinalPullRequestInstruction.body(for:note:)` が `nil`）
    case invalidInstruction
    /// トークンの持ち主が、そのリポジトリで信用する author ではない（投稿しても指示として読まれない）
    case untrustedAccount(String)
}

/// 最終 PR に指示を投稿する。テストでは差し替える
public protocol FinalPullRequestInstructionPosting: Sendable {
    /// 最終 PR に、1 件の指摘を直させる指示を 1 件のコメントとして投稿し、投稿したコメントの URL を返す
    func post(fixing thread: CodeRabbitReviewThread, note: String, to pullRequest: EpicPullRequest) async throws -> URL
}

/// GitHub の API で最終 PR に指示を投稿する。投稿の前に、トークンの持ち主がそのリポジトリで信用する author であることを確かめる
/// （信用しない author のコメントは指示として読まれないので、投稿しても無駄になる）。トークンには Pull requests（Issues）の書き込み権限が要る
public struct GitHubFinalPullRequestInstructionPoster: FinalPullRequestInstructionPosting {
    private let client: GitHubClient
    private let trustedAuthors: any TrustedAuthorsResolving

    public init(client: GitHubClient, trustedAuthors: any TrustedAuthorsResolving = TrustedAuthors.default) {
        self.client = client
        self.trustedAuthors = trustedAuthors
    }

    public func post(fixing thread: CodeRabbitReviewThread, note: String, to pullRequest: EpicPullRequest) async throws -> URL {
        guard let body = FinalPullRequestInstruction.body(for: thread, note: note) else {
            throw FinalPullRequestInstructionError.invalidInstruction
        }
        let viewer = try await client.graphQL("query { viewer { login } }", as: ViewerData.self).viewer.login
        guard await trustedAuthors.trustedAuthors(for: pullRequest.repository).contains(viewer) else {
            throw FinalPullRequestInstructionError.untrustedAccount(viewer)
        }
        // PR の会話のコメントは Issue のコメントの API で付ける
        let comment = try await client.send(
            "POST",
            "repos/\(pullRequest.repository)/issues/\(pullRequest.number)/comments",
            body: ["body": body],
            as: PostedInstruction.self
        )
        return comment.htmlURL
    }
}

private struct ViewerData: Decodable {
    struct Viewer: Decodable {
        let login: String
    }

    let viewer: Viewer
}

private struct PostedInstruction: Decodable {
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
    }
}
