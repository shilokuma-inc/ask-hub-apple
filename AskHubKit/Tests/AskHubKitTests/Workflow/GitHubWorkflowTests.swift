@testable import AskHubKit
import Foundation
import Testing

struct GitHubWorkflowTests {
    private let sleeper = SleepRecorder()

    private func makeClient(_ http: MockHTTPClient) -> GitHubClient {
        let sleeper = sleeper
        return GitHubClient(
            token: "github_pat_secret",
            http: http,
            sleep: { sleeper.sleep($0) },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
    }

    private func makeWorkflow(_ http: MockHTTPClient, file: String = "release-prepare.yml") -> GitHubWorkflow {
        GitHubWorkflow(client: makeClient(http), file: file)
    }

    private static func runJSON(id: Int, branch: String = "develop", displayTitle: String? = "Release/Prepare") -> String {
        let titleJSON = displayTitle.map { #""\#($0)""# } ?? "null"
        return #"""
            { "id": \#(id), "head_branch": "\#(branch)", "head_sha": "sha\#(id)", "status": "completed", "conclusion": "success",
              "event": "workflow_dispatch", "run_started_at": "2026-10-15T09:00:00Z", "created_at": "2026-10-15T08:59:00Z",
              "html_url": "https://github.com/o/r/actions/runs/\#(id)", "display_title": \#(titleJSON) }
            """#
    }

    private static func queryItems(_ request: URLRequest) throws -> [URLQueryItem] {
        let url = try #require(request.url)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    // MARK: - 有無

    @Test func reportsActiveAndDisabledWorkflows() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "id": 1, "name": "Release/Prepare", "state": "active" }"#),
            .init(status: 200, body: #"{ "id": 1, "state": "disabled_manually" }"#),
            .init(status: 404, body: #"{ "message": "Not Found" }"#)
        ])
        let workflow = makeWorkflow(http)
        #expect(try await workflow.availability(repository: "o/r") == .active)
        #expect(try await workflow.availability(repository: "o/r") == .disabled(state: "disabled_manually"))
        let missing = try await workflow.availability(repository: "o/r")
        #expect(missing == .notFound)
        #expect(!missing.isActive)

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path() == "/repos/o/r/actions/workflows/release-prepare.yml")
    }

    @Test func availabilityDistinguishesPermissionDeniedFromRateLimit() async throws {
        let denied = MockHTTPClient([.init(status: 403, body: #"{ "message": "Resource not accessible by personal access token" }"#)])
        await #expect(throws: WorkflowError.permissionDenied) {
            try await makeWorkflow(denied).availability(repository: "o/r")
        }
        let limited = MockHTTPClient([
            .init(status: 429, body: "{}", headers: ["Retry-After": "5"]),
            .init(status: 200, body: #"{ "state": "active" }"#)
        ])
        #expect(try await makeWorkflow(limited).availability(repository: "o/r") == .active)
        #expect(sleeper.recorded == [.seconds(5)])
    }

    // MARK: - run の一覧

    @Test func fetchesRecentRunsFilteredByBranchAndEvent() async throws {
        let runs = [Self.runJSON(id: 8, displayTitle: "Release/Prepare 1.1.0"), Self.runJSON(id: 7)].joined(separator: ",")
        let http = MockHTTPClient([
            .init(
                status: 200,
                body: #"{ "total_count": 30, "workflow_runs": [\#(runs)] }"#,
                // 次のページがあっても追わない（直近の数件だけが要る）
                headers: ["Link": #"<https://api.github.com/repos/o/r/actions/workflows/release-prepare.yml/runs?page=2>; rel="next""#]
            )
        ])
        let result = try await makeWorkflow(http).recentRuns(repository: "o/r", branch: "develop", event: "workflow_dispatch", limit: 5)

        #expect(result.map(\.id) == [8, 7])
        #expect(result.first?.displayTitle == "Release/Prepare 1.1.0")
        #expect(result.first?.branch == "develop")
        #expect(result.first?.isSuccessful == true)
        #expect(http.requests.count == 1)
        let request = try #require(http.requests.first)
        #expect(request.url?.path() == "/repos/o/r/actions/workflows/release-prepare.yml/runs")
        let items = try Self.queryItems(request)
        #expect(items.contains(URLQueryItem(name: "branch", value: "develop")))
        #expect(items.contains(URLQueryItem(name: "event", value: "workflow_dispatch")))
        #expect(items.contains(URLQueryItem(name: "per_page", value: "5")))
    }

    @Test func recentRunsClampsLimitAndOmitsFilters() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "total_count": 0, "workflow_runs": [] }"#),
            .init(status: 200, body: #"{ "total_count": 0, "workflow_runs": [] }"#)
        ])
        let workflow = makeWorkflow(http)
        #expect(try await workflow.recentRuns(repository: "o/r", limit: 500).isEmpty)
        #expect(try await workflow.recentRuns(repository: "o/r", limit: 0).isEmpty)

        let first = try Self.queryItems(http.requests[0])
        #expect(first == [URLQueryItem(name: "per_page", value: "100")])
        let second = try Self.queryItems(http.requests[1])
        #expect(second == [URLQueryItem(name: "per_page", value: "1")])
    }

    @Test func recentRunsThrowsForMissingWorkflowAndPermission() async {
        let missing = MockHTTPClient([.init(status: 404, body: #"{ "message": "Not Found" }"#)])
        await #expect(throws: WorkflowError.workflowNotFound) {
            try await makeWorkflow(missing).recentRuns(repository: "o/r")
        }
        let denied = MockHTTPClient([.init(status: 403, body: #"{ "message": "Forbidden" }"#)])
        await #expect(throws: WorkflowError.permissionDenied) {
            try await makeWorkflow(denied).recentRuns(repository: "o/r")
        }
    }

    @Test func latestRunUsesTheGivenFileAndKeepsDisplayTitle() async throws {
        let run3 = Self.runJSON(id: 3, branch: "release/1.1.0", displayTitle: nil)
        let http = MockHTTPClient([.init(status: 200, body: #"{ "total_count": 1, "workflow_runs": [\#(run3)] }"#)])
        let result = try await makeWorkflow(http, file: "release-notes.yml").latestRun(repository: "o/r", branch: "release/1.1.0")
        let run = try #require(result.run)
        #expect(run.displayTitle == nil)
        #expect(run.branch == "release/1.1.0")
        #expect(http.requests.first?.url?.path() == "/repos/o/r/actions/workflows/release-notes.yml/runs")
    }

    // MARK: - 起動

    @Test func dispatchesWithInputs() async throws {
        let http = MockHTTPClient([.init(status: 204, body: "")])
        try await makeWorkflow(http).dispatch(repository: "o/r", ref: "develop", inputs: ["version": "1.1.0", "resume": "true"])

        let request = try #require(http.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path() == "/repos/o/r/actions/workflows/release-prepare.yml/dispatches")
        let data = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["ref"] as? String == "develop")
        #expect(json["inputs"] as? [String: String] == ["version": "1.1.0", "resume": "true"])
        // トークンは Authorization ヘッダーにだけ載り、URL や本文には出ない
        #expect(request.url?.absoluteString.contains("github_pat_secret") == false)
        #expect(String(bytes: data, encoding: .utf8)?.contains("github_pat_secret") == false)
    }

    @Test func dispatchOmitsEmptyInputs() async throws {
        let http = MockHTTPClient([.init(status: 204, body: "")])
        try await makeWorkflow(http).dispatch(repository: "o/r", ref: "develop")
        let data = try #require(http.requests.first?.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json == ["ref": "develop"])
    }

    @Test func classifiesDispatchRejections() async throws {
        let cases: [(String?, DispatchRejection)] = [
            ("Workflow does not have 'workflow_dispatch' trigger", .noWorkflowDispatchTrigger),
            ("Cannot trigger a 'workflow_dispatch' on a disabled workflow", .workflowDisabled),
            ("No ref found for: release/9.9.9", .refNotFound),
            (#"Unexpected inputs provided: ["foo"]"#, .invalidInputs),
            ("Required input 'version' not provided", .invalidInputs),
            ("Something else", .other),
            (nil, .other)
        ]
        for (message, expected) in cases {
            let body = message.map { #"{ "message": "\#($0.replacingOccurrences(of: "\"", with: "\\\""))" }"# } ?? ""
            let http = MockHTTPClient([.init(status: 422, body: body)])
            do {
                try await makeWorkflow(http).dispatch(repository: "o/r", ref: "develop", inputs: ["version": "1.1.0"])
                Issue.record("422 なのに成功した")
            } catch let error as WorkflowError {
                #expect(error == .dispatchNotSupported(message: message))
                #expect(error.dispatchRejection == expected)
            }
        }
        #expect(WorkflowError.permissionDenied.dispatchRejection == nil)
        #expect(WorkflowError.workflowNotFound.dispatchRejection == nil)
    }

    // MARK: - Upload

    @Test func uploadWorkflowCanUseAnotherFile() async throws {
        let http = MockHTTPClient([
            .init(status: 200, body: #"{ "total_count": 0, "workflow_runs": [] }"#),
            .init(status: 204, body: "")
        ])
        let upload = GitHubUploadWorkflow(client: makeClient(http), workflowFile: "upload-beta.yml")
        #expect(try await upload.latestRun(repository: "o/r", branch: "epic/mvp") == .noRuns)
        try await upload.dispatch(repository: "o/r", ref: "epic/mvp")
        #expect(http.requests.map { $0.url?.path() } == [
            "/repos/o/r/actions/workflows/upload-beta.yml/runs",
            "/repos/o/r/actions/workflows/upload-beta.yml/dispatches"
        ])
        #expect(GitHubUploadWorkflow.workflowFile == "upload.yml")
    }
}
