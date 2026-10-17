@testable import AskHubKit
import Foundation
import Testing

struct ManualLoopFinalInstructionsTests {
    private static func pull(
        _ number: Int,
        head: String,
        body: String?,
        author: String? = "mrs1669",
        labels: [String] = ["epic-final"]
    ) -> String {
        let bodyJSON = body.map { #""\#($0.replacingOccurrences(of: "\n", with: "\\n"))""# } ?? "null"
        let user = author.map { #"{"login":"\#($0)"}"# } ?? "null"
        let labelsJSON = labels.map { #"{"name":"\#($0)"}"# }.joined(separator: ",")
        return #"{"number":\#(number),"body":\#(bodyJSON),"head":{"ref":"\#(head)"},"user":\#(user),"labels":[\#(labelsJSON)]}"#
    }

    private static func comment(_ id: Int, _ author: String, _ body: String, at seconds: Int) -> String {
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + seconds)))
        return #"{"id":\#(id),"user":{"login":"\#(author)"},"body":"\#(body)","created_at":"\#(date)"}"#
    }

    private static func checker(_ http: MockHTTPClient) -> GitHubManualLoopFinalInstructions {
        GitHubManualLoopFinalInstructions(
            client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }),
            trustedAuthors: TrustedAuthors(["mrs1669"])
        )
    }

    @Test func readsGoalDiscussionMarker() {
        #expect(GoalDiscussionMarker.discussion(in: "ゴール元: Discussion #12\n<!-- ask-hub:discussion 12 -->\n\n- まとめ") == 12)
        #expect(GoalDiscussionMarker.discussion(in: "ゴール元: Discussion #12\r\n<!-- ask-hub:discussion 12 -->\r\n") == 12)
        #expect(GoalDiscussionMarker.discussion(in: "- まとめ") == nil)
        // 先頭の数行より後の目印は読まない
        #expect(GoalDiscussionMarker.discussion(in: "a\nb\nc\n<!-- ask-hub:discussion 12 -->") == nil)
    }

    @Test func findsManualLoopsWithUnprocessedInstructionOnFinalPullRequest() async throws {
        let marked = "ゴール元: Discussion #21\n<!-- ask-hub:discussion 21 -->\n\n- まとめ"
        let http = MockHTTPClient([
            .init(status: 200, body: "[" + [
                Self.pull(70, head: "epic/other", body: marked),
                Self.pull(71, head: "feat/x", body: nil, labels: []),
                Self.pull(72, head: "epic/b", body: "- まとめ"),
                // 信用しない author が作った最終 PR は見ない
                Self.pull(73, head: "epic/c", body: "- まとめ", author: "someone")
            ].joined(separator: ",") + "]"),
            // #21 の最終 PR（目印で対応）: 返信より後に指示がある
            .init(status: 200, body: "[" + [
                Self.comment(3, "mrs1669", "#discussion_r9 も直して", at: 30),
                Self.comment(1, "mrs1669", "#discussion_r8 を直して", at: 10),
                Self.comment(2, "mrs1669", "\(FinalPullRequestMarker.reply)\\n直しました", at: 20)
            ].joined(separator: ",") + "]"),
            // #22 の最終 PR（head のブランチで対応）: 指示は処理済み
            .init(status: 200, body: "[" + [
                Self.comment(4, "mrs1669", "#discussion_r10 を直して", at: 10),
                Self.comment(5, "mrs1669", "\(FinalPullRequestMarker.reply)\\n直しました", at: 20),
                Self.comment(6, "someone", "#discussion_r11 を直して", at: 30)
            ].joined(separator: ",") + "]")
        ])
        let loops = [
            ManualLoopTarget(repository: "o/r", discussion: 21, epic: "epic/a"),
            ManualLoopTarget(repository: "o/r", discussion: 22, epic: "epic/b"),
            ManualLoopTarget(repository: "o/r", discussion: 23, epic: "epic/c"),
            ManualLoopTarget(repository: "o/r", discussion: 24, epic: nil)
        ]

        let pending = try await Self.checker(http).loopsWithUnprocessedInstructions(loops)

        #expect(pending == ["o/r#21"])
        let paths = http.requests.compactMap { $0.url?.path() }
        #expect(paths == ["/repos/o/r/pulls", "/repos/o/r/issues/70/comments", "/repos/o/r/issues/72/comments"])
    }

    @Test func checksEachRepositoryAndToleratesFailureOfOne() async throws {
        let marked = "ゴール元: Discussion #5\n<!-- ask-hub:discussion 5 -->"
        let http = MockHTTPClient([
            // リポジトリは名前（小文字）の順に読む。a/one は一覧の取得に失敗する
            .init(status: 500, body: "{}"),
            .init(status: 200, body: "[" + Self.pull(80, head: "epic/z", body: marked) + "]"),
            .init(status: 200, body: "[" + Self.comment(1, "mrs1669", "#discussion_r1 を直して", at: 0) + "]")
        ])
        let loops = [
            ManualLoopTarget(repository: "B/Two", discussion: 5, epic: nil),
            ManualLoopTarget(repository: "a/one", discussion: 3, epic: "epic/y")
        ]

        let pending = try await Self.checker(http).loopsWithUnprocessedInstructions(loops)

        #expect(pending == ["b/two#5"])
        let paths = http.requests.compactMap { $0.url?.path() }
        #expect(paths == ["/repos/a/one/pulls", "/repos/B/Two/pulls", "/repos/B/Two/issues/80/comments"])
    }

    @Test func stopsAtRateLimit() async throws {
        let http = MockHTTPClient([.init(status: 429, body: "{}", headers: ["Retry-After": "3600"])])
        let loops = [
            ManualLoopTarget(repository: "a/one", discussion: 3, epic: nil),
            ManualLoopTarget(repository: "b/two", discussion: 5, epic: nil)
        ]
        await #expect(throws: GitHubError.rateLimited(retryAfter: .seconds(3600))) {
            try await Self.checker(http).loopsWithUnprocessedInstructions(loops)
        }
        #expect(http.requests.count == 1)
    }

    @Test func doesNotMatchMarkedPullRequestOfAnotherDiscussionByBranch() {
        let pulls = [
            FinalPullRequestSummary(
                number: 70, body: "ゴール元: Discussion #9\n<!-- ask-hub:discussion 9 -->", head: .init(ref: "epic/a"), user: nil, labels: []
            )
        ]
        let target = ManualLoopTarget(repository: "o/r", discussion: 21, epic: "epic/a")
        #expect(GitHubManualLoopFinalInstructions.finalPullRequest(of: target, in: pulls) == nil)
    }

    @Test func doesNothingWithoutManualLoops() async throws {
        let http = MockHTTPClient([])
        #expect(try await Self.checker(http).loopsWithUnprocessedInstructions([]).isEmpty)
        #expect(http.requests.isEmpty)
    }
}
