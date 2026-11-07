@testable import AskHubPullRequests
import Foundation
import Testing

struct ChecksTests {
    // MARK: - 応答の形

    private static func run(
        _ name: String,
        status: String = "completed",
        conclusion: String? = "success",
        startedAt: Date = Fixture.now,
        actions: (run: Int, job: Int)? = nil
    ) -> [String: Any] {
        let details = actions.map { "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/\($0.run)/job/\($0.job)" }
        return [
            "id": actions?.job ?? 1,
            "name": name,
            "status": status,
            "conclusion": conclusion.map { $0 as Any } ?? NSNull(),
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "details_url": details ?? "https://example.com/check",
            "html_url": "https://github.com/shilokuma-inc/ask-hub-apple/runs/1",
            "app": ["slug": actions == nil ? "other-app" : "github-actions"]
        ]
    }

    private static func runs(_ runs: [[String: Any]]) -> String {
        Fixture.json(["total_count": runs.count, "check_runs": runs])
    }

    private static func statuses(_ statuses: [(context: String, state: String)]) -> String {
        let items = statuses.map { ["context": $0.context, "state": $0.state, "target_url": "https://coderabbit.ai"] }
        return Fixture.json(["state": "pending", "total_count": items.count, "statuses": items])
    }

    private func summary(
        runs: [[String: Any]],
        statuses: [(context: String, state: String)] = [],
        policy: CheckPolicy = CheckPolicy()
    ) async throws -> CheckSummary {
        let transport = StubTransport([.json(200, Self.runs(runs)), .json(200, Self.statuses(statuses))])
        return try await Fixture.client(transport).checks(at: Fixture.sha, policy: policy)
    }

    // MARK: - 読み方

    @Test func readsCheckRunsAndStatusesFollowingPages() async throws {
        let next = "https://api.github.com/repositories/1/commits/\(Fixture.sha)/check-runs?page=2"
        let nextStatus = "https://api.github.com/repositories/1/commits/\(Fixture.sha)/status?page=2"
        let transport = StubTransport([
            .json(200, Self.runs([Self.run("build")]), headers: Fixture.link(next: next)),
            .json(200, Self.runs([Self.run("test", conclusion: "failure", actions: (run: 111, job: 222))])),
            .json(200, Self.statuses([("CodeRabbit", "success")]), headers: Fixture.link(next: nextStatus)),
            .json(200, Self.statuses([("deploy", "pending")]))
        ])
        let summary = try await Fixture.client(transport).checks(at: Fixture.sha)
        #expect(summary.verdict == .failed)
        #expect(summary.failures == [
            FailedCheck(
                name: "test",
                source: .checkRun,
                conclusion: "failure",
                runID: 111,
                jobID: 222,
                detailsURL: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/111/job/222")
            )
        ])
        #expect(summary.unfinished == ["deploy"])

        let requests = transport.requests
        #expect(requests.count == 4)
        #expect(Fixture.path(requests[0]) == "/repos/shilokuma-inc/ask-hub-apple/commits/\(Fixture.sha)/check-runs")
        #expect(Fixture.query(requests[0]) == ["filter": "latest", "per_page": "100"])
        #expect(requests[1].url?.absoluteString == next)
        #expect(Fixture.path(requests[2]) == "/repos/shilokuma-inc/ask-hub-apple/commits/\(Fixture.sha)/status")
        #expect(Fixture.query(requests[2]) == ["per_page": "100"])
        #expect(requests[3].url?.absoluteString == nextStatus)
    }

    @Test func passesWhenEveryCheckSucceeded() async throws {
        let summary = try await summary(
            runs: [Self.run("build"), Self.run("lint", conclusion: "neutral"), Self.run("ui", conclusion: "skipped")],
            statuses: [("CodeRabbit", "success")]
        )
        #expect(summary == CheckSummary(verdict: .passed))
    }

    @Test func waitsWhileNothingIsReported() async throws {
        // CI がまだ始まっていないのを成功とみなさない
        #expect(try await summary(runs: []).verdict == .pending)
    }

    @Test func waitsForRunningChecks() async throws {
        let summary = try await summary(runs: [Self.run("build", status: "in_progress", conclusion: nil), Self.run("lint")])
        #expect(summary.verdict == .pending)
        #expect(summary.unfinished == ["build"])
    }

    @Test func ignoresChecksNotRequired() async throws {
        // CodeRabbit の commit status や、待たないワークフローの失敗は見ない
        let summary = try await summary(
            runs: [Self.run("build"), Self.run("optional", conclusion: "failure")],
            statuses: [("CodeRabbit", "pending")],
            policy: CheckPolicy(required: ["build"])
        )
        #expect(summary == CheckSummary(verdict: .passed))
    }

    @Test func waitsForRequiredChecksNotYetReported() async throws {
        let summary = try await summary(runs: [Self.run("build")], policy: CheckPolicy(required: ["build", "test"]))
        #expect(summary.verdict == .pending)
        #expect(summary.missing == ["test"])
    }

    @Test func emptyRequiredSetWaitsForNothing() async throws {
        #expect(try await summary(runs: [], policy: CheckPolicy(required: [])).verdict == .passed)
    }

    @Test func failsIfAnyOfSameNamedChecksFailed() async throws {
        // push と pull_request の両方で同じワークフローが走ると、同じ名前の check run が 2 つ並ぶ
        let summary = try await summary(
            runs: [Self.run("build"), Self.run("build", conclusion: "failure", actions: (run: 5, job: 6))],
            policy: CheckPolicy(required: ["build"])
        )
        #expect(summary.verdict == .failed)
        #expect(summary.failures.map(\.runID) == [5])
    }

    @Test(arguments: ["failure", "timed_out", "cancelled", "action_required", "stale", "startup_failure"])
    func treatsUnsuccessfulConclusionsAsFailed(_ conclusion: String) async throws {
        let summary = try await summary(runs: [Self.run("build", conclusion: conclusion)])
        #expect(summary.verdict == .failed)
        #expect(summary.failures.map(\.conclusion) == [conclusion])
        // GitHub Actions でなければ run の id は無い
        #expect(summary.failures.map(\.runID) == [nil])
    }

    @Test(arguments: ["failure", "error"])
    func treatsFailedStatusesAsFailed(_ state: String) async throws {
        let summary = try await summary(runs: [Self.run("build")], statuses: [("ci/legacy", state)])
        #expect(summary.verdict == .failed)
        #expect(summary.failures == [
            FailedCheck(name: "ci/legacy", source: .commitStatus, conclusion: state, detailsURL: URL(string: "https://coderabbit.ai"))
        ])
    }

    @Test func reportsRunnerShortageWhenQueuedTooLong() async throws {
        let queued = Self.run("build", status: "queued", conclusion: nil, startedAt: Fixture.now.addingTimeInterval(-31 * 60))
        let summary = try await summary(runs: [queued, Self.run("lint")], policy: CheckPolicy(queuedLimit: .seconds(30 * 60)))
        #expect(summary.verdict == .runnerShortage)
        #expect(summary.starved == ["build"])
        #expect(summary.unfinished == ["build"])
    }

    @Test func waitsWhileQueuedWithinLimit() async throws {
        let queued = Self.run("build", status: "queued", conclusion: nil, startedAt: Fixture.now.addingTimeInterval(-29 * 60))
        let summary = try await summary(runs: [queued], policy: CheckPolicy(queuedLimit: .seconds(30 * 60)))
        #expect(summary.verdict == .pending)
        #expect(summary.starved.isEmpty)
    }

    @Test func failureOutranksRunnerShortage() async throws {
        let queued = Self.run("ui", status: "queued", conclusion: nil, startedAt: Fixture.now.addingTimeInterval(-3_600))
        let summary = try await summary(runs: [queued, Self.run("build", conclusion: "failure")])
        #expect(summary.verdict == .failed)
        #expect(summary.starved == ["ui"])
    }

    @Test func refusesSHAOfWrongShapeWithoutSending() async throws {
        let transport = StubTransport([])
        await #expect(throws: PullRequestError.invalidArgument("SHA の形が違う")) {
            try await Fixture.client(transport).checks(at: "main")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func readsActionsIDsWithoutJobInURL() {
        // URL に job が無ければ、check run の id（GitHub Actions では job の id と同じ）を使う
        let payload = CheckRunPayload(
            id: 99,
            name: "build",
            status: "completed",
            conclusion: "failure",
            startedAt: nil,
            detailsUrl: "https://github.com/o/r/actions/runs/42",
            htmlUrl: nil,
            app: CheckRunPayload.App(slug: "github-actions")
        )
        #expect(payload.actionsIDs().map { [$0.run, $0.job] } == [42, 99])
    }
}
