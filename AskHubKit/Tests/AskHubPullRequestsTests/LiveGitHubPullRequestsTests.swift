import AskHubProtocol
@testable import AskHubPullRequests
import Foundation
import Testing

/// 本物の GitHub で、PR・CI・レビューを読めることを確かめる（読むだけ）。ふだん（CI を含む）は流さない。
///
/// PR のあるリポジトリと番号とトークンを環境変数で渡したときだけ流す。信用する書き手は `ASKHUB_LIVE_TEST_TRUSTED`（カンマ区切り。
/// 既定は `coderabbitai[bot]`）。トークンは表示しない:
/// `ASKHUB_LIVE_TEST_PR_REPO=<owner/repo> ASKHUB_LIVE_TEST_PR_NUMBER=<番号> ASKHUB_LIVE_TEST_TOKEN="$(gh auth token)"
///  swift test --package-path AskHubKit --filter LiveGitHubPullRequests`
@Suite(.enabled(if: LivePullRequestEnvironment.isEnabled))
struct LiveGitHubPullRequestsTests {
    @Test func readsPullRequestChecksAndReviews() async throws {
        let repository = try #require(LivePullRequestEnvironment.repository)
        let number = try #require(LivePullRequestEnvironment.number)
        let token = try #require(LivePullRequestEnvironment.token)
        let client = GitHubPullRequests(repository: repository) { token }

        let pullRequest = try await client.pullRequest(number: number)
        #expect(pullRequest.number == number)
        #expect(pullRequest.headSHA.count == 40)

        let observed = try await client.observedChecks(at: pullRequest.headSHA)
        let summary = ObservedCheck.summarize(observed, policy: CheckPolicy(), now: Date())
        print("チェック \(observed.count) 件: \(summary.verdict)、落ちた \(summary.failures.map(\.name))、終わっていない \(summary.unfinished)")

        let trusted = TrustedAuthors(LivePullRequestEnvironment.trusted)
        let feedback = try await client.reviewFeedback(number: number, trusted: trusted)
        print("未解決のスレッド \(feedback.threads.count) 件・レビューの本文 \(feedback.reviews.count) 件")
        let authors = feedback.threads.flatMap(\.comments).map(\.author) + feedback.reviews.map(\.author)
        #expect(authors.allSatisfy { trusted.logins.contains($0.lowercased()) })

        if pullRequest.state == .open {
            let found = try await client.openPullRequest(head: pullRequest.headRef, base: pullRequest.baseRef)
            #expect(found?.number == number)
        }
    }
}

enum LivePullRequestEnvironment {
    private static let environment = ProcessInfo.processInfo.environment
    static let repository = environment["ASKHUB_LIVE_TEST_PR_REPO"].flatMap(RepositoryFullName.init(rawValue:))
    static let number = environment["ASKHUB_LIVE_TEST_PR_NUMBER"].flatMap(Int.init)
    static let token = environment["ASKHUB_LIVE_TEST_TOKEN"]
    static let trusted = (environment["ASKHUB_LIVE_TEST_TRUSTED"] ?? "coderabbitai[bot]").split(separator: ",").map(String.init)
    static let isEnabled = repository != nil && number != nil && token != nil
}
