@testable import AskHubPullRequests
import Foundation
import Testing

/// GitHub Actions の実行の読み取りと、PR の閉じる・開き直す
struct ActionsTests {
    private static func run(_ id: Int, name: Any = "Build", event: String = "push", status: String = "queued") -> [String: Any] {
        [
            "id": id,
            "name": name,
            "event": event,
            "status": status,
            "conclusion": NSNull(),
            "created_at": "2026-11-11T18:00:00Z",
            "run_started_at": "2026-11-11T18:00:05Z"
        ]
    }

    private static func runs(_ runs: [[String: Any]]) -> String {
        Fixture.json(["total_count": runs.count, "workflow_runs": runs])
    }

    @Test func readsWorkflowRunsOfHeadFollowingPages() async throws {
        let next = "https://api.github.com/repositories/1/actions/runs?head_sha=\(Fixture.sha)&page=2"
        var unnamed = Self.run(102, name: NSNull(), event: "pull_request", status: "completed")
        unnamed["run_started_at"] = NSNull()
        let transport = StubTransport([
            .json(200, Self.runs([Self.run(101)]), headers: Fixture.link(next: next)),
            .json(200, Self.runs([unnamed]))
        ])
        let runs = try await Fixture.client(transport).workflowRuns(at: Fixture.sha)
        let started = try #require(ISO8601DateFormatter().date(from: "2026-11-11T18:00:05Z"))
        let created = try #require(ISO8601DateFormatter().date(from: "2026-11-11T18:00:00Z"))
        #expect(runs == [
            WorkflowRun(id: 101, name: "Build", event: "push", status: "queued", startedAt: started),
            // 名前の無いワークフローは空の名前、始まった時刻が無ければ作られた時刻
            WorkflowRun(id: 102, name: "", event: "pull_request", status: "completed", startedAt: created)
        ])
        let requests = transport.requests
        #expect(Fixture.path(requests[0]) == "/repos/shilokuma-inc/ask-hub-apple/actions/runs")
        #expect(Fixture.query(requests[0]) == ["head_sha": Fixture.sha, "per_page": "100"])
        #expect(requests[1].url?.absoluteString == next)
    }

    @Test func refusesMalformedSHABeforeSending() async {
        let transport = StubTransport([])
        await #expect(throws: PullRequestError.invalidArgument("SHA の形が違う")) {
            try await Fixture.client(transport).workflowRuns(at: "main")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func readsOnlyJobCountOfRun() async throws {
        // 2026-11-12 の止まった実行は、queued のまま total_count が 0 だった
        let transport = StubTransport([.json(200, Fixture.json(["total_count": 0, "jobs": []]))])
        let count = try await Fixture.client(transport).jobCount(runID: 19_000_000_001)
        #expect(count == 0)
        let request = transport.requests.first
        #expect(Fixture.path(request) == "/repos/shilokuma-inc/ask-hub-apple/actions/runs/19000000001/jobs")
        #expect(Fixture.query(request) == ["per_page": "1"])
    }

    @Test func closesAndReopensPullRequest() async throws {
        let transport = StubTransport([.json(200, Fixture.json(Fixture.pull(41))), .json(200, Fixture.json(Fixture.pull(41)))])
        let client = Fixture.client(transport)
        try await client.setState(number: 41, to: .closed)
        try await client.setState(number: 41, to: .open)
        let requests = transport.requests
        #expect(requests.map(\.httpMethod) == ["PATCH", "PATCH"])
        #expect(requests.map(Fixture.path) == Array(repeating: "/repos/shilokuma-inc/ask-hub-apple/pulls/41", count: 2))
        #expect(Fixture.body(requests[0]) as? [String: String] == ["state": "closed"])
        #expect(Fixture.body(requests[1]) as? [String: String] == ["state": "open"])
    }

    @Test func reportsRejectedReopen() async {
        // 開き直せない（head のブランチが消えたなど）は 422
        let transport = StubTransport([.json(422, #"{"message":"Validation Failed"}"#)])
        await #expect(throws: PullRequestError.rejected(message: "Validation Failed")) {
            try await Fixture.client(transport).setState(number: 41, to: .open)
        }
    }
}
