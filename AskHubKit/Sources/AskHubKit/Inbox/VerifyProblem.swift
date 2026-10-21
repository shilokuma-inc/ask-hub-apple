import Foundation

/// 実機確認で問題があったときの、再修正の依頼と実機確認 Issue へのコメント
/// （`docs/protocol.md` の「実機確認で問題があったとき（アプリからの「問題あり」）」。Issue #483）
public struct VerifyProblem: Sendable, Equatable {
    /// 問題のあった実機確認（`needs-verify`）の Issue
    public let issue: InboxIssue
    /// 問題の内容（何をしたら・どうなったか）
    public var description: String

    public init(issue: InboxIssue, description: String) {
        self.issue = issue
        self.description = description
    }

    /// 実機確認 Issue へのコメントの先頭に置く目印
    public static let marker = "<!-- ask-hub:verify-problem -->"

    /// 前後の空白・改行を除いた問題の内容
    public var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 送ってよい形か。実機確認の Issue で、問題の内容が空でないこと
    public var isValid: Bool {
        issue.kind == .needsVerify && !trimmedDescription.isEmpty
    }

    /// 実機確認 Issue と同じリポジトリに作る再修正の依頼。
    /// タイトルは `【依頼】実機確認の問題: <一覧の表示と同じタイトル>`。本文は実機確認 Issue の URL・元の PR・epic と問題の内容
    public var request: IdeaRequest {
        IdeaRequest(repository: issue.repository, summary: "実機確認の問題: \(Self.singleLine(issue.displayTitle))", body: requestBody)
    }

    /// 依頼の本文。`元の PR`・`epic` の行は、実機確認 Issue の目印にその値があるときだけ書く
    var requestBody: String {
        var header = ["実機確認 Issue: \(issue.url.absoluteString)"]
        if let pullRequest = issue.verifyMarker?.pullRequest {
            header.append("元の PR: #\(pullRequest)")
        }
        if let epic = issue.verifyMarker?.epic {
            header.append("epic: \(epic)")
        }
        return header.joined(separator: "\n") + "\n\n" + trimmedDescription
    }

    /// 実機確認 Issue へのコメント。目印を先頭に置き、問題の内容（依頼の本文と同じ）と作った依頼の番号を書く
    public func comment(request number: Int) -> String {
        "\(Self.marker)\n\(trimmedDescription)\n\n再修正の依頼: #\(number)"
    }

    /// Issue のタイトルは 1 行だが、念のため改行を空白にする（依頼の要約は 1 行でないと送れない）
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// 実機確認 Issue へ「問題あり」のコメントを投稿する。テストでは差し替える
public protocol VerifyProblemCommenting: Sendable {
    /// `request` は先に作った再修正の依頼。投稿したコメントの URL を返す
    func post(_ problem: VerifyProblem, request: CreatedIssue) async throws -> URL
}

/// 「問題あり」を送れないときのエラー
public enum VerifyProblemError: Error, Equatable, Sendable {
    /// 実機確認ではない Issue、または問題の内容が空
    case invalidProblem
}

/// GitHub の REST API で実機確認 Issue にコメントする。トークンには Issues の書き込み権限が要る。
/// Issue は閉じず、ラベルも変えない（再修正の後にもう一度確かめてから閉じる）
public struct GitHubVerifyProblemCommenter: VerifyProblemCommenting {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func post(_ problem: VerifyProblem, request: CreatedIssue) async throws -> URL {
        guard problem.isValid else {
            throw VerifyProblemError.invalidProblem
        }
        let comment = try await client.send(
            "POST",
            "repos/\(problem.issue.repository)/issues/\(problem.issue.number)/comments",
            body: ["body": problem.comment(request: request.number)],
            as: PostedComment.self
        )
        return comment.htmlURL
    }
}

private struct PostedComment: Decodable {
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
    }
}
