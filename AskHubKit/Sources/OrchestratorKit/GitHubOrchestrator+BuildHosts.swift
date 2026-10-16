import AskHubKit
import Foundation

// ビルドの Mac の状態の Issue（build-hosts）の読み書き。状態用の Issue（loop-status）と同じ API を使う
extension GitHubOrchestrator {
    public func buildHostsIssues(in repository: String) async throws -> [LoopStatusIssueRecord] {
        try await statusIssues(labeled: BuildHostsReport.labelName, in: repository)
    }

    public func createBuildHostsIssue(in repository: String, body: String) async throws -> Int {
        // 色・説明は scripts/ralph-setup.sh のラベル作成とそろえる
        try await createStatusIssue(
            in: repository,
            title: BuildHostsReport.issueTitle,
            body: body,
            label: StatusLabel(name: BuildHostsReport.labelName, color: "BFD4F2", description: "ビルドの Mac の状態（オーケストレーターが書き換える）")
        )
    }

    public func updateBuildHostsIssue(in repository: String, number: Int, body: String) async throws {
        try await updateStatusIssue(in: repository, number: number, body: body)
    }
}
