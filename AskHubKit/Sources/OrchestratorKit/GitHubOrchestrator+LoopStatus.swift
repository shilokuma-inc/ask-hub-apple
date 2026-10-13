import AskHubKit
import Foundation

// 状態用の Issue（loop-status）の読み書き
extension GitHubOrchestrator {
    public func loopStatusIssues(in repository: String) async throws -> [LoopStatusIssueRecord] {
        try await statusIssues(labeled: LoopStatusReport.labelName, in: repository)
    }

    /// ラベルの付いた Issue（閉じたものも含む）。状態を書き出す Issue（`loop-status` / `build-hosts`）に使う
    func statusIssues(labeled label: String, in repository: String) async throws -> [LoopStatusIssueRecord] {
        let issues = try await client.getAllPages(
            "repos/\(repository)/issues",
            query: [
                URLQueryItem(name: "labels", value: label),
                // 閉じられたものは開き直して使う
                URLQueryItem(name: "state", value: "all")
            ],
            of: LoopStatusIssueSummary.self
        )
        // Issue の API は PR も返すので除く
        return issues.filter { $0.pullRequest == nil }.map {
            LoopStatusIssueRecord(
                number: $0.number,
                author: $0.user?.login,
                isOpen: $0.state == "open",
                updatedAt: $0.updatedAt,
                body: $0.body ?? ""
            )
        }
    }

    public func createLoopStatusIssue(in repository: String, body: String) async throws -> Int {
        try await createStatusIssue(
            in: repository,
            title: LoopStatusReport.issueTitle,
            body: body,
            label: StatusLabel(name: LoopStatusReport.labelName, color: "bfdadc", description: "AskHub のオーケストレーターがループの状態を書き出す Issue")
        )
    }

    /// 状態を書き出す Issue のラベル
    struct StatusLabel: Encodable, Sendable {
        let name: String
        let color: String
        let description: String
    }

    /// 状態を書き出す Issue を作る（ラベルが無ければ作る）。Issue の番号を返す
    func createStatusIssue(in repository: String, title: String, body: String, label: StatusLabel) async throws -> Int {
        try await ensureLabel(label, in: repository)
        let issue = try await client.send(
            "POST",
            "repos/\(repository)/issues",
            body: NewLoopStatusIssue(title: title, body: body, labels: [label.name]),
            as: LoopStatusIssueNumber.self
        )
        return issue.number
    }

    public func updateLoopStatusIssue(in repository: String, number: Int, body: String) async throws {
        try await updateStatusIssue(in: repository, number: number, body: body)
    }

    /// ループごとのコメントは同じリポジトリのループの数だけあり、古いループのものも残りうるので、ページングを最後まで追う
    public func loopStatusComments(in repository: String, issue number: Int) async throws -> [LoopStatusComment] {
        try await client.getAllPages("repos/\(repository)/issues/\(number)/comments", of: LoopStatusCommentSummary.self).map {
            LoopStatusComment(id: $0.id, author: $0.user?.login, updatedAt: $0.updatedAt, body: $0.body ?? "")
        }
    }

    public func createLoopStatusComment(in repository: String, issue number: Int, body: String) async throws -> Int {
        try await client.send(
            "POST",
            "repos/\(repository)/issues/\(number)/comments",
            body: ["body": body],
            as: LoopStatusCommentID.self
        ).id
    }

    public func updateLoopStatusComment(in repository: String, id: Int, body: String) async throws {
        _ = try await client.send(
            "PATCH",
            "repos/\(repository)/issues/comments/\(id)",
            body: ["body": body],
            as: LoopStatusCommentID.self
        )
    }

    /// 状態を書き出す Issue の本文を置き換える
    func updateStatusIssue(in repository: String, number: Int, body: String) async throws {
        // 閉じられていれば開き直す（open のままなら何も変わらない）
        _ = try await client.send(
            "PATCH",
            "repos/\(repository)/issues/\(number)",
            body: ["body": body, "state": "open"],
            as: LoopStatusIssueNumber.self
        )
    }

    /// ラベルが無ければ作る（Issue の作成で、無いラベルを付けられないことがあるため）
    private func ensureLabel(_ label: StatusLabel, in repository: String) async throws {
        do {
            _ = try await client.send("POST", "repos/\(repository)/labels", body: label, as: LoopStatusLabelName.self)
        } catch GitHubError.http(status: 422, _) {
            // 既にある
        }
    }
}

private struct LoopStatusIssueSummary: Decodable {
    struct User: Decodable {
        let login: String
    }

    /// PR のときだけある
    struct PullRequestLink: Decodable {}

    let number: Int
    let state: String
    let body: String?
    let user: User?
    let updatedAt: Date
    let pullRequest: PullRequestLink?

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case body
        case user
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }
}

private struct LoopStatusCommentSummary: Decodable {
    struct User: Decodable {
        let login: String
    }

    let id: Int
    let user: User?
    let body: String?
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case user
        case body
        case updatedAt = "updated_at"
    }
}

private struct LoopStatusCommentID: Decodable {
    let id: Int
}

private struct NewLoopStatusIssue: Encodable, Sendable {
    let title: String
    let body: String
    let labels: [String]
}

private struct LoopStatusIssueNumber: Decodable {
    let number: Int
}

private struct LoopStatusLabelName: Decodable {
    let name: String
}
