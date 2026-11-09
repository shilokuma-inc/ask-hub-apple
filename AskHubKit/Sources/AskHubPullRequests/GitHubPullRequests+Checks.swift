import Foundation

extension GitHubPullRequests {
    /// head の SHA の CI を読み、まとめた状態を返す。
    ///
    /// check run（GitHub Actions など）と commit status（CodeRabbit など）の両方を、ページングを最後まで追って読む。
    /// check run は名前ごとの最新（`filter=latest`）、commit status は context ごとの最新（combined status）を見る
    public func checks(at sha: String, policy: CheckPolicy = CheckPolicy()) async throws(PullRequestError) -> CheckSummary {
        let observed = try await observedChecks(at: sha)
        return ObservedCheck.summarize(observed, policy: policy, now: api.now())
    }

    /// head の SHA のチェックを、check run と commit status をそろえた形で読む
    func observedChecks(at sha: String) async throws(PullRequestError) -> [ObservedCheck] {
        let runs = try await checkRunPayloads(at: sha)
        let statuses = try await api.pages("commits/\(sha)/status", query: [Self.perPage], as: CombinedStatusPage.self)
        return runs.map { $0.observed() } + statuses.flatMap(\.statuses).map { $0.observed() }
    }

    /// head の SHA の check run（名前ごとの最新）を、ページングを最後まで追って読む。
    /// CodeRabbit は、レビューの様子を check run `CodeRabbit` で出し、完了・上限での見送り・見送りを conclusion と見出しで分けるので、見出しも返す
    public func checkRuns(at sha: String) async throws(PullRequestError) -> [CheckRunStatus] {
        try await checkRunPayloads(at: sha).map(\.checkRunStatus)
    }

    private static let perPage = URLQueryItem(name: "per_page", value: "100")

    private func checkRunPayloads(at sha: String) async throws(PullRequestError) -> [CheckRunPayload] {
        try GitNames.checkSHA(sha)
        let pages = try await api.pages(
            "commits/\(sha)/check-runs",
            query: [URLQueryItem(name: "filter", value: "latest"), Self.perPage],
            as: CheckRunsPage.self
        )
        return pages.flatMap(\.checkRuns)
    }

    /// head の SHA の commit status（context ごとの最新）を、ページングを最後まで追って読む。
    /// CodeRabbit は、レビューの完了・上限での見送り・見送りを、どれも `success` の説明の文言だけで分けるので、説明も返す
    public func commitStatuses(at sha: String) async throws(PullRequestError) -> [CommitStatus] {
        try GitNames.checkSHA(sha)
        let query = [URLQueryItem(name: "per_page", value: "100")]
        let pages = try await api.pages("commits/\(sha)/status", query: query, as: CombinedStatusPage.self)
        return pages.flatMap(\.statuses).map { CommitStatus(context: $0.context, state: $0.state, description: $0.description) }
    }
}

/// check run の今の様子と結果の見出し
public struct CheckRunStatus: Sendable, Equatable {
    public var name: String
    /// 入れたアプリ（`github-actions`・`coderabbitai` など）。アプリが消えると nil
    public var app: String?
    /// `queued`・`in_progress`・`completed`（GitHub Actions は `waiting`・`requested`・`pending` も使う）
    public var status: String
    /// 終わるまでは nil
    public var conclusion: String?
    /// 結果の見出し（CodeRabbit は "Finished"・"Review rate limited"・"Review skipped" など）。無ければ nil
    public var title: String?

    public init(name: String, app: String?, status: String, conclusion: String? = nil, title: String? = nil) {
        self.name = name
        self.app = app
        self.status = status
        self.conclusion = conclusion
        self.title = title
    }
}

/// commit status（以前の CodeRabbit など）の今の様子
public struct CommitStatus: Sendable, Equatable {
    public var context: String
    /// `error`・`failure`・`pending`・`success`
    public var state: String
    /// 説明（CodeRabbit は "Review completed"・"Review rate limited" など）。無ければ nil
    public var description: String?

    public init(context: String, state: String, description: String? = nil) {
        self.context = context
        self.state = state
        self.description = description
    }
}

// MARK: - 応答の形（キーは `convertFromSnakeCase` で読む）

struct CheckRunsPage: Decodable {
    let checkRuns: [CheckRunPayload]
}

struct CheckRunPayload: Decodable {
    struct App: Decodable {
        let slug: String?
    }

    struct Output: Decodable {
        let title: String?
    }

    let id: Int
    let name: String
    /// `queued`・`in_progress`・`completed`（GitHub Actions は `waiting`・`requested`・`pending` も使う）
    let status: String
    /// 終わるまでは null
    let conclusion: String?
    /// 時刻と URL は、ほかのアプリが入れた値で一覧ごと読めなくならないよう、文字列で受けて読めるものだけ使う
    let startedAt: String?
    let detailsUrl: String?
    let htmlUrl: String?
    /// アプリが消えると null になる
    let app: App?
    let output: Output?

    var checkRunStatus: CheckRunStatus {
        CheckRunStatus(name: name, app: app?.slug, status: status, conclusion: conclusion, title: output?.title)
    }

    /// 成功とみなす conclusion。ほか（`failure`・`timed_out`・`cancelled`・`action_required`・`stale` と知らない値）は落ちたとみなす
    static let passingConclusions: Set<String> = ["success", "neutral", "skipped"]

    func observed() -> ObservedCheck {
        switch status {
        case "completed":
            let conclusion = conclusion ?? "unknown"
            if Self.passingConclusions.contains(conclusion) { return ObservedCheck(name: name, progress: .succeeded) }
            let ids = actionsIDs()
            let failure = FailedCheck(
                name: name,
                source: .checkRun,
                conclusion: conclusion,
                runID: ids?.run,
                jobID: ids?.job,
                detailsURL: (detailsUrl ?? htmlUrl).flatMap(URL.init(string:))
            )
            return ObservedCheck(name: name, progress: .failed(failure))
        case "queued":
            return ObservedCheck(name: name, progress: .queued(since: startedAt.flatMap(GitHubDate.parse)))
        default:
            return ObservedCheck(name: name, progress: .running)
        }
    }

    /// GitHub Actions の run と job の id。`details_url` は `https://github.com/<owner>/<repo>/actions/runs/<run>/job/<job>`。
    /// Actions の check run の id は job の id と同じなので、URL に job が無ければ check run の id を使う
    func actionsIDs() -> (run: Int, job: Int)? {
        guard app?.slug == "github-actions" else { return nil }
        for url in [detailsUrl, htmlUrl].compactMap({ $0.flatMap(URL.init(string:)) }) {
            let parts = url.pathComponents
            guard let runs = parts.firstIndex(of: "runs"), runs + 1 < parts.count, let run = Int(parts[runs + 1]) else { continue }
            let job = parts.firstIndex(of: "job").flatMap { $0 + 1 < parts.count ? Int(parts[$0 + 1]) : nil }
            return (run, job ?? id)
        }
        return nil
    }
}

struct CombinedStatusPage: Decodable {
    let statuses: [CommitStatusPayload]
}

struct CommitStatusPayload: Decodable {
    let context: String
    /// `error`・`failure`・`pending`・`success`
    let state: String
    let description: String?
    let targetUrl: String?

    func observed() -> ObservedCheck {
        switch state {
        case "success":
            return ObservedCheck(name: context, progress: .succeeded)
        case "pending":
            return ObservedCheck(name: context, progress: .running)
        default:
            let url = targetUrl.flatMap(URL.init(string:))
            let failure = FailedCheck(name: context, source: .commitStatus, conclusion: state, detailsURL: url)
            return ObservedCheck(name: context, progress: .failed(failure))
        }
    }
}

/// GitHub の時刻（ISO 8601。小数の秒があってもよい）
enum GitHubDate {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
