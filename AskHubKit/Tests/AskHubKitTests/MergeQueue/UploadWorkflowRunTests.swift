@testable import AskHubKit
import Foundation
import Testing

extension UploadWorkflowRun {
    static func fixture(
        status: Status = .completed,
        conclusion: Conclusion? = .success,
        headSHA: String = "abc123"
    ) -> Self {
        Self(
            id: 1,
            repository: "shilokuma-inc/ask-hub-apple",
            branch: "epic/mvp",
            headSHA: headSHA,
            status: status,
            conclusion: conclusion,
            event: "workflow_dispatch",
            startedAt: Date(timeIntervalSince1970: 1_000),
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/actions/runs/1")!
        )
    }
}

struct UploadWorkflowRunTests {
    @Test func runningUntilCompleted() {
        #expect(UploadWorkflowRun.fixture(status: .queued, conclusion: nil).isRunning)
        #expect(UploadWorkflowRun.fixture(status: .inProgress, conclusion: nil).isRunning)
        #expect(UploadWorkflowRun.fixture(status: .other("waiting"), conclusion: nil).isRunning)
        #expect(!UploadWorkflowRun.fixture(status: .completed, conclusion: .failure).isRunning)
    }

    @Test func successfulOnlyWhenCompletedWithSuccess() {
        #expect(UploadWorkflowRun.fixture().isSuccessful)
        #expect(!UploadWorkflowRun.fixture(conclusion: .cancelled).isSuccessful)
        #expect(!UploadWorkflowRun.fixture(status: .inProgress, conclusion: nil).isSuccessful)
    }

    @Test func comparesBuiltHeadIgnoringCase() {
        #expect(UploadWorkflowRun.fixture(headSHA: "ABC123").builtHead("abc123"))
        #expect(!UploadWorkflowRun.fixture(headSHA: "abc123").builtHead("def456"))
    }

    @Test func mapsUnknownStatusAndConclusion() {
        #expect(UploadWorkflowRun.Status(rawValue: "in_progress") == .inProgress)
        #expect(UploadWorkflowRun.Status(rawValue: "requested") == .other("requested"))
        #expect(UploadWorkflowRun.Conclusion(rawValue: "timed_out") == .other("timed_out"))
        #expect(LatestUploadRun.run(.fixture()).run == .fixture())
        #expect(LatestUploadRun.noRuns.run == nil)
    }
}

struct GitHubUploadWorkflowTests {
    private let sleeper = SleepRecorder()

    private func makeWorkflow(_ http: MockHTTPClient) -> GitHubUploadWorkflow {
        let sleeper = sleeper
        let client = GitHubClient(
            token: "github_pat_secret",
            http: http,
            sleep: { sleeper.sleep($0) },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        return GitHubUploadWorkflow(client: client)
    }

    private static func runJSON(
        id: Int,
        status: String?,
        conclusion: String?,
        event: String = "workflow_dispatch",
        runStartedAt: String? = "2026-10-15T09:00:00Z",
        headBranch: String? = "epic/mvp"
    ) -> String {
        let statusJSON = status.map { #""\#($0)""# } ?? "null"
        let conclusionJSON = conclusion.map { #""\#($0)""# } ?? "null"
        let startedJSON = runStartedAt.map { #""\#($0)""# } ?? "null"
        let branchJSON = headBranch.map { #""\#($0)""# } ?? "null"
        return #"""
            { "id": \#(id), "head_branch": \#(branchJSON), "head_sha": "sha\#(id)",
              "status": \#(statusJSON), "conclusion": \#(conclusionJSON),
              "event": "\#(event)", "run_started_at": \#(startedJSON), "created_at": "2026-10-15T08:59:00Z",
              "html_url": "https://github.com/o/r/actions/runs/\#(id)" }
            """#
    }

    @Test func fetchesLatestRunForBranchWithoutPaging() async throws {
        let http = MockHTTPClient([
            .init(
                status: 200,
                body: #"{ "total_count": 2, "workflow_runs": [\#(Self.runJSON(id: 2, status: "in_progress", conclusion: nil))] }"#,
                // 2 ページ目があっても追わない（直近の 1 件だけが要る）
                headers: ["Link": #"<https://api.github.com/repos/o/r/actions/workflows/upload.yml/runs?branch=epic%2Fmvp&per_page=1&page=2>; rel="next""#]
            )
        ])
        let result = try await makeWorkflow(http).latestRun(repository: "o/r", branch: "epic/mvp")

        let run = try #require(result.run)
        #expect(run.id == 2)
        #expect(run.repository == "o/r")
        #expect(run.branch == "epic/mvp")
        #expect(run.headSHA == "sha2")
        #expect(run.status == .inProgress)
        #expect(run.conclusion == nil)
        #expect(run.isRunning)
        #expect(run.event == "workflow_dispatch")
        #expect(run.startedAt == Date(timeIntervalSince1970: 1_792_054_800))
        #expect(run.url.absoluteString == "https://github.com/o/r/actions/runs/2")

        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/repos/o/r/actions/workflows/upload.yml/runs")
        let url = try #require(request.url)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "branch", value: "epic/mvp")))
        #expect(items.contains(URLQueryItem(name: "per_page", value: "1")))
    }

    @Test func fallsBackToCreatedAtAndReadsConclusion() async throws {
        let run3 = Self.runJSON(id: 3, status: "completed", conclusion: "success", event: "push", runStartedAt: nil)
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "total_count": 1, "workflow_runs": [\#(run3)] }"#)
        ])
        let run = try #require(try await makeWorkflow(http).latestRun(repository: "o/r", branch: "epic/mvp").run)
        #expect(run.isSuccessful)
        #expect(run.event == "push")
        #expect(run.startedAt == Date(timeIntervalSince1970: 1_792_054_740))
    }

    @Test func reportsNoRunsForBranch() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{ "total_count": 0, "workflow_runs": [] }"#)])
        let result = try await makeWorkflow(http).latestRun(repository: "o/r", branch: "epic/mvp")
        #expect(result == .noRuns)
    }

    @Test func keepsUnknownStatusAndFallsBackToRequestedBranch() async throws {
        // status は API の定義上 null になりうる。head_branch が無ければ問い合わせたブランチを入れる
        let waiting = Self.runJSON(id: 4, status: "waiting", conclusion: nil, headBranch: nil)
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "total_count": 1, "workflow_runs": [\#(waiting)] }"#),
            .init(status: 200, body: #"{ "total_count": 1, "workflow_runs": [\#(Self.runJSON(id: 5, status: nil, conclusion: nil))] }"#)
        ])
        let workflow = makeWorkflow(http)
        let run4 = try #require(try await workflow.latestRun(repository: "o/r", branch: "epic/mvp").run)
        #expect(run4.status == .other("waiting"))
        #expect(run4.isRunning)
        #expect(run4.branch == "epic/mvp")
        let run5 = try #require(try await workflow.latestRun(repository: "o/r", branch: "epic/mvp").run)
        #expect(run5.status == .other(""))
        #expect(run5.isRunning)
    }

    @Test func treatsMissingWorkflowAsUnsupported() async throws {
        let http = MockHTTPClient([.init(status: 404, body: #"{ "message": "Not Found" }"#)])
        let result = try await makeWorkflow(http).latestRun(repository: "o/r", branch: "epic/mvp")
        #expect(result == .unsupported)
    }

    @Test func distinguishesPermissionDeniedFromRateLimit() async throws {
        // レート制限ではない 403 は権限不足
        let denied = MockHTTPClient([.init(status: 403, body: #"{ "message": "Resource not accessible by personal access token" }"#)])
        await #expect(throws: UploadWorkflowError.permissionDenied) {
            try await makeWorkflow(denied).latestRun(repository: "o/r", branch: "epic/mvp")
        }
        #expect(sleeper.recorded.isEmpty)

        // x-ratelimit-remaining: 0 の 403 はレート制限として待って再試行する
        let limited = MockHTTPClient([
            .init(status: 403, body: "{}", headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1010"]),
            .init(status: 200, body: #"{ "total_count": 0, "workflow_runs": [] }"#)
        ])
        let result = try await makeWorkflow(limited).latestRun(repository: "o/r", branch: "epic/mvp")
        #expect(result == .noRuns)
        #expect(sleeper.recorded == [.seconds(11)])

        // Retry-After の無い 429 も 60 秒待つレート制限で、権限不足にはしない
        let secondary = MockHTTPClient([
            .init(status: 429, body: "{}"),
            .init(status: 200, body: #"{ "total_count": 0, "workflow_runs": [] }"#)
        ])
        #expect(try await makeWorkflow(secondary).latestRun(repository: "o/r", branch: "epic/mvp") == .noRuns)
        #expect(sleeper.recorded == [.seconds(11), .seconds(60)])
    }

    @Test func surfacesRateLimitWhenRetriesAreExhausted() async {
        let http = MockHTTPClient([.init(status: 403, body: "{}", headers: ["Retry-After": "3600"])])
        await #expect(throws: GitHubError.rateLimited(retryAfter: .seconds(3600))) {
            try await makeWorkflow(http).latestRun(repository: "o/r", branch: "epic/mvp")
        }
    }

    @Test func propagatesOtherErrors() async {
        let http = MockHTTPClient([.init(status: 500, body: #"{ "message": "boom" }"#)])
        await #expect(throws: GitHubError.http(status: 500, message: "boom")) {
            try await makeWorkflow(http).latestRun(repository: "o/r", branch: "epic/mvp")
        }
    }
}
