@testable import AskHubKit
import Foundation
import os
import Testing

/// 書き込み権限を持つアカウントを返す。呼ばれた回数を数え、失敗させることもできる
final class StubWritersSource: RepositoryWritersSource {
    private struct State {
        var writers: [String: [String]]
        var fails = false
        var calls: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ writers: [String: [String]]) {
        state = OSAllocatedUnfairLock(initialState: State(writers: writers))
    }

    var calls: [String] {
        state.withLock { $0.calls }
    }

    func setFails(_ fails: Bool) {
        state.withLock { $0.fails = fails }
    }

    func setWriters(_ writers: [String], of repository: String) {
        state.withLock { $0.writers[repository] = writers }
    }

    func writers(of repository: String) async throws -> [String] {
        try state.withLock { state in
            state.calls.append(repository)
            if state.fails {
                throw GitHubError.http(status: 403, message: "Must have push access")
            }
            return state.writers[repository] ?? []
        }
    }
}

struct RepositoryTrustTests {
    @Test func listsAccountsWithWritePermissionOrHigher() async throws {
        let body = #"""
            [{ "login": "mrs1669", "permissions": { "admin": true, "maintain": true, "push": true } },
             { "login": "partner", "permissions": { "admin": false, "maintain": false, "push": true } },
             { "login": "maintainer", "permissions": { "admin": false, "maintain": true, "push": false } },
             { "login": "reader", "permissions": { "admin": false, "maintain": false, "push": false } },
             { "login": "unknown" }]
            """#
        let http = MockHTTPClient([.init(status: 200, body: body)])
        let source = GitHubRepositoryWriters(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))

        let writers = try await source.writers(of: "shilokuma-inc/notti-ios")

        #expect(writers == ["mrs1669", "partner", "maintainer"])
        let request = try #require(http.requests.first)
        #expect(request.url?.path() == "/repos/shilokuma-inc/notti-ios/collaborators")
        // チーム・organization の既定の権限で書ける人も含める
        #expect(request.url?.query()?.contains("affiliation=all") == true)
    }

    @Test func addsWritersToBaseForEachRepository() async {
        let source = StubWritersSource(["o/app": ["Partner"], "o/other": []])
        let trust = RepositoryTrust(base: TrustedAuthors(["mrs1669"]), writers: RepositoryWriters(source: source))

        let app = await trust.trustedAuthors(for: "o/app")
        let other = await trust.trustedAuthors(for: "o/other")

        #expect(app.contains("mrs1669"))
        #expect(app.contains("partner"))
        // 書き込み権限はリポジトリごと。別のリポジトリでは信用しない
        #expect(!other.contains("partner"))
        #expect(other.contains("mrs1669"))
    }

    @Test func reusesResultUntilLifetimeEnds() async {
        let source = StubWritersSource(["o/app": ["partner"]])
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        let writers = RepositoryWriters(source: source, lifetime: .seconds(600), now: { clock.withLock { $0 } })

        _ = await writers.writers(of: "o/app")
        _ = await writers.writers(of: "O/App")
        #expect(source.calls == ["o/app"])

        // 招待した人は、次に取り直したときから信用する
        source.setWriters(["partner", "newcomer"], of: "o/app")
        clock.withLock { $0 = $0.addingTimeInterval(601) }
        let refreshed = await writers.writers(of: "o/app")
        #expect(source.calls.count == 2)
        #expect(refreshed?.contains("newcomer") == true)
    }

    @Test func keepsPreviousResultOrFallsBackToBaseWhenFetchFails() async {
        let source = StubWritersSource(["o/app": ["partner"]])
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
        let writers = RepositoryWriters(source: source, lifetime: .seconds(600), now: { clock.withLock { $0 } })
        let trust = RepositoryTrust(base: TrustedAuthors(["mrs1669"]), writers: writers)
        #expect(await trust.trustedAuthors(for: "o/app").contains("partner"))

        // 取り直しに失敗したら、前回の結果を使う
        source.setFails(true)
        clock.withLock { $0 = $0.addingTimeInterval(601) }
        #expect(await trust.trustedAuthors(for: "o/app").contains("partner"))

        // 一度も取れていない（push 権限の無い）リポジトリでは、設定の一覧だけ。失敗も覚えて、すぐには取り直さない
        let none = await trust.trustedAuthors(for: "o/private")
        #expect(none.sortedLogins == ["mrs1669"])
        _ = await trust.trustedAuthors(for: "o/private")
        #expect(source.calls.filter { $0 == "o/private" }.count == 1)
    }

    @Test func fetcherJudgesAnswersWithTrustOfEachRepository() async throws {
        // 共同開発者（partner）は o/app にだけ書き込み権限がある
        let source = StubWritersSource(["o/app": ["partner"], "o/other": []])
        let trust = RepositoryTrust(base: TrustedAuthors(["mrs1669"]), writers: RepositoryWriters(source: source))
        let inbox = PartnerAnsweredInbox()

        let questions = try await InboxFetcher(source: inbox, trustedAuthors: trust).unansweredQuestions(orgs: ["o"])

        // o/app では partner の回答で回答済み。o/other では partner は信用しないので未回答のまま
        #expect(questions.map(\.subject.repository) == ["o/other"])
    }
}

/// o/app と o/other の Discussion に、mrs1669 の質問と partner の回答が 1 つずつある
private struct PartnerAnsweredInbox: InboxSource {
    func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
        ["o/app", "o/other"].enumerated().map { index, repository in
            InboxSubject(
                kind: .discussion,
                nodeID: "D_\(index)",
                repository: repository,
                number: index + 1,
                title: "依頼",
                url: URL(string: "https://github.com/\(repository)/discussions/\(index + 1)")!,
                author: "mrs1669"
            )
        }
    }

    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        let comment = InboxComment(
            nodeID: "C_\(subject.nodeID)",
            databaseID: 1,
            author: "mrs1669",
            body: #"<!-- ask-hub:question id="q1" options="A|B" -->"# + "\n### Q1. どちらにしますか",
            url: subject.url,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return [QuestionThread(comment: comment, replyAuthors: ["partner"])]
    }

    func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        []
    }
}
