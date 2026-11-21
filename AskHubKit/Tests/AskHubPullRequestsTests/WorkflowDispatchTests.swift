@testable import AskHubPullRequests
import Foundation
import Testing

/// ワークフローの起動と、その実行の見張り（App Store のスクショの撮影）
struct WorkflowDispatchTests {
    private static func run(_ id: Int, branch: String = "release/1.2.0", status: String = "in_progress") -> [String: Any] {
        [
            "id": id,
            "status": status,
            "conclusion": NSNull(),
            "event": "workflow_dispatch",
            "path": ".github/workflows/app-store-screenshots.yml",
            "head_branch": branch,
            "head_sha": Fixture.sha,
            "created_at": "2026-11-22T01:00:03Z",
            "html_url": "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/\(id)"
        ]
    }

    @Test func dispatchesWithRunDetailsAndReadsTheRunID() async throws {
        let reply = Fixture.json([
            "workflow_run_id": 44_900_000_101,
            "run_url": "https://api.github.com/repos/shilokuma-inc/ask-hub-apple/actions/runs/44900000101",
            "html_url": "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/44900000101"
        ])
        let transport = StubTransport([.json(200, reply)])
        let run = try await Fixture.client(transport).dispatchWorkflow(
            "app-store-screenshots.yml", ref: "release/1.2.0", inputs: ["upload": "false", "display_types": "APP_IPHONE_67"]
        )
        #expect(run == DispatchedRun(
            id: 44_900_000_101, url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/44900000101")
        ))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(Fixture.path(request) == "/repos/shilokuma-inc/ask-hub-apple/actions/workflows/app-store-screenshots.yml/dispatches")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["ref"] as? String == "release/1.2.0")
        #expect(body["return_run_details"] as? Bool == true)
        #expect(body["inputs"] as? [String: String] == ["upload": "false", "display_types": "APP_IPHONE_67"])
    }

    @Test func returnsNoRunForTheOldEmptyReply() async throws {
        // return_run_details を知らない形（204）なら、呼ぶ側が一覧から探す
        let transport = StubTransport([.init(status: 204)])
        let run = try await Fixture.client(transport).dispatchWorkflow("app-store-screenshots.yml", ref: "release/1.2.0", inputs: [:])
        #expect(run == nil)
    }

    @Test func refusesAWorkflowOutsideTheWorkflowsFolderBeforeSending() async {
        let transport = StubTransport([])
        await #expect(throws: PullRequestError.invalidArgument("ワークフローのファイル名の形が違う")) {
            try await Fixture.client(transport).dispatchWorkflow("../upload.yml", ref: "release/1.2.0", inputs: [:])
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func passesTheMissingWorkflowThrough() async {
        let transport = StubTransport([.json(404, Fixture.json(["message": "Not Found"]))])
        await #expect(throws: PullRequestError.notFound) {
            try await Fixture.client(transport).dispatchWorkflow("app-store-screenshots.yml", ref: "release/1.2.0", inputs: [:])
        }
    }

    @Test func readsOneRun() async throws {
        var completed = Self.run(44_900_000_101, status: "completed")
        completed["conclusion"] = "success"
        let transport = StubTransport([.json(200, Fixture.json(completed))])
        let run = try await Fixture.client(transport).workflowRun(id: 44_900_000_101)
        #expect(run.isCompleted && run.conclusion == "success" && run.headBranch == "release/1.2.0" && run.headSHA == Fixture.sha)
        #expect(run.url?.absoluteString == "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/44900000101")
        #expect(Fixture.path(transport.requests.first) == "/repos/shilokuma-inc/ask-hub-apple/actions/runs/44900000101")
    }

    @Test func readsDispatchedRunsOfTheBranch() async throws {
        var broken = Self.run(44_900_000_100)
        broken["head_sha"] = NSNull()
        let transport = StubTransport([.json(200, Fixture.json(["total_count": 2, "workflow_runs": [Self.run(44_900_000_101), broken]]))])
        let runs = try await Fixture.client(transport).dispatchedRuns("app-store-screenshots.yml", branch: "release/1.2.0")
        // 欄の欠けた実行は飛ばす
        #expect(runs.map(\.id) == [44_900_000_101])
        let request = transport.requests.first
        #expect(Fixture.path(request) == "/repos/shilokuma-inc/ask-hub-apple/actions/workflows/app-store-screenshots.yml/runs")
        #expect(Fixture.query(request) == ["branch": "release/1.2.0", "event": "workflow_dispatch", "per_page": "100"])
    }

    @Test func cancelsARun() async throws {
        let transport = StubTransport([.init(status: 202)])
        try await Fixture.client(transport).cancelWorkflowRun(id: 44_900_000_101)
        let request = transport.requests.first
        #expect(request?.httpMethod == "POST")
        #expect(Fixture.path(request) == "/repos/shilokuma-inc/ask-hub-apple/actions/runs/44900000101/cancel")
    }
}
