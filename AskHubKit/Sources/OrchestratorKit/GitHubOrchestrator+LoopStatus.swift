import AskHubKit
import Foundation

// 状態用の Issue（loop-status）の読み書き
extension GitHubOrchestrator {
    public func loopStatusIssues(in repository: String) async throws -> [LoopStatusIssueRecord] {
        let issues = try await client.getAllPages(
            "repos/\(repository)/issues",
            query: [
                URLQueryItem(name: "labels", value: LoopStatusReport.labelName),
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
        try await ensureLoopStatusLabel(in: repository)
        let issue = try await client.send(
            "POST",
            "repos/\(repository)/issues",
            body: NewLoopStatusIssue(title: LoopStatusReport.issueTitle, body: body, labels: [LoopStatusReport.labelName]),
            as: LoopStatusIssueNumber.self
        )
        return issue.number
    }

    public func updateLoopStatusIssue(in repository: String, number: Int, body: String) async throws {
        // 閉じられていれば開き直す（open のままなら何も変わらない）
        _ = try await client.send(
            "PATCH",
            "repos/\(repository)/issues/\(number)",
            body: ["body": body, "state": "open"],
            as: LoopStatusIssueNumber.self
        )
    }

    /// 状態用のラベルが無ければ作る（Issue の作成で、無いラベルを付けられないことがあるため）
    private func ensureLoopStatusLabel(in repository: String) async throws {
        do {
            _ = try await client.send(
                "POST",
                "repos/\(repository)/labels",
                body: ["name": LoopStatusReport.labelName, "color": "bfdadc", "description": "AskHub のオーケストレーターがループの状態を書き出す Issue"],
                as: LoopStatusLabelName.self
            )
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
