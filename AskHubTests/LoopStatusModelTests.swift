@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct LoopStatusModelTests {
    private struct FailingSource: LoopStatusSource {
        func loopStatusRepositories(org: String) async throws -> [LoopStatusRepository] {
            throw GitHubError.http(status: 401, message: nil)
        }
    }

    private struct EmptySource: LoopStatusSource {
        func loopStatusRepositories(org: String) async throws -> [LoopStatusRepository] {
            []
        }
    }

    /// 「上限で待機中」「ループの開始待ち」だけを返す受信箱の取得元。`nil` の取得は失敗させる
    private struct SectionsSource: InboxSource {
        var waiting: [WaitingDiscussion]?
        var usageLimited: [UsageLimitedRepository]?

        func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject] {
            []
        }

        func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
            []
        }

        func lowPriorityIssues(org: String) async throws -> [InboxIssue] {
            []
        }

        func waitingDiscussions(org: String) async throws -> [WaitingDiscussion] {
            guard let waiting else {
                throw GitHubError.http(status: 502, message: nil)
            }
            return waiting
        }

        func usageLimitedRepositories(org: String, now: Date) async throws -> [UsageLimitedRepository] {
            guard let usageLimited else {
                throw GitHubError.http(status: 502, message: nil)
            }
            return usageLimited
        }
    }

    private static func waiting(_ repository: String, number: Int, author: String) -> WaitingDiscussion {
        WaitingDiscussion(
            subject: InboxSubject(
                kind: .discussion,
                nodeID: "\(repository)#\(number)",
                repository: repository,
                number: number,
                title: "ゴール",
                url: URL(string: "https://github.com/\(repository)/discussions/\(number)")!
            ),
            lastSeen: nil,
            author: author
        )
    }

    private static func model(
        token: String? = "sample",
        rows: any LoopStatusSource = EmptySource(),
        sections: any InboxSource
    ) -> LoopStatusModel {
        LoopStatusModel(
            tokenStore: InMemoryTokenStore(token: token),
            makeSource: { _ in rows },
            makeInboxSource: { _ in sections }
        )
    }

    @Test func loadsSampleRowsCoveringEveryStatus() async {
        let model = LoopStatusModel.sample()
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.rows.count == 10)
        let now = Date()
        let displays = model.rows.map { $0.display(now: now) }
        #expect(displays.contains { $0.isStuck })
        #expect(displays.contains { $0.statusText == "担当 PC なし" })
        #expect(displays.contains { $0.statusText == "状態なし" })
        #expect(displays.contains { $0.statusText.hasPrefix("上限で待機中（") })
        let reported = Set(model.rows.compactMap { row in
            if case let .reported(report) = row.status(now: now) { report.state } else { nil }
        })
        #expect(reported == Set(LoopStatusReport.State.allCases).subtracting([.unknown]))
    }

    @Test func loadsSampleWaitingDiscussionsAndUsageLimitedWithRows() async {
        let model = LoopStatusModel.sample()
        await model.refresh()

        #expect(model.waiting.map(\.subject.shortReference) == ["ask-hub-apple#15", "beat-tap-ios#3"])
        // 印の新しいリポジトリは担当 PC あり、印の無いリポジトリは担当 PC なし
        #expect(model.waiting.map { $0.isAssigned(now: Date()) } == [true, false])
        #expect(model.usageLimited.map(\.repository) == ["shilokuma-inc/notti-ios"])
    }

    @Test func waitingDiscussionsOnlyFromTrustedAuthorsSortedByNumber() async {
        let trusted = TrustedAuthors.defaultLogins[0]
        let model = Self.model(sections: SectionsSource(
            waiting: [
                Self.waiting("shilokuma-inc/notti-ios", number: 12, author: trusted),
                Self.waiting("shilokuma-inc/ask-hub-apple", number: 30, author: "someone-else"),
                Self.waiting("shilokuma-inc/ask-hub-apple", number: 15, author: trusted)
            ],
            usageLimited: []
        ))
        await model.refresh()
        #expect(model.waiting.map(\.subject.shortReference) == ["ask-hub-apple#15", "notti-ios#12"])
    }

    @Test func toleratesUsageLimitedFailure() async {
        let model = Self.model(sections: SectionsSource(
            waiting: [Self.waiting("shilokuma-inc/ask-hub-apple", number: 15, author: TrustedAuthors.defaultLogins[0])],
            usageLimited: nil
        ))
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.usageLimited.isEmpty)
        #expect(model.waiting.count == 1)
    }

    @Test func reportsWaitingDiscussionsFailure() async {
        let model = Self.model(rows: SampleLoopStatusSource(), sections: SectionsSource(waiting: nil, usageLimited: []))
        await model.refresh()
        guard case .failed = model.state else {
            Issue.record("開始待ちの取得の失敗が状態に出ていない: \(model.state)")
            return
        }
    }

    @Test func isEmptyOnlyWithoutRowsAndSections() async {
        let sectionsOnly = Self.model(sections: SectionsSource(
            waiting: [],
            usageLimited: [UsageLimitedRepository(repository: "shilokuma-inc/notti-ios", until: Date().addingTimeInterval(60 * 60))]
        ))
        await sectionsOnly.refresh()
        #expect(sectionsOnly.rows.isEmpty)
        #expect(!sectionsOnly.isEmpty)

        let empty = Self.model(sections: SectionsSource(waiting: [], usageLimited: []))
        await empty.refresh()
        #expect(empty.state == .loaded)
        #expect(empty.isEmpty)
    }

    @Test func needsToken() async {
        let model = Self.model(token: nil, rows: SampleLoopStatusSource(), sections: SampleInboxSource())
        await model.refresh()
        #expect(model.state == .needsToken)
        #expect(model.isEmpty)
    }

    @Test func clearsSectionsWhenTokenIsRemoved() async throws {
        let tokenStore = InMemoryTokenStore(token: "sample")
        let model = LoopStatusModel(
            tokenStore: tokenStore,
            makeSource: { _ in SampleLoopStatusSource() },
            makeInboxSource: { _ in SampleInboxSource() }
        )
        await model.refresh()
        #expect(!model.waiting.isEmpty)
        #expect(!model.usageLimited.isEmpty)

        try tokenStore.delete()
        await model.refresh()
        #expect(model.state == .needsToken)
        #expect(model.isEmpty)
    }

    @Test func reportsFailureWithoutToken() async {
        let model = Self.model(token: "github_pat_secret", rows: FailingSource(), sections: SampleInboxSource())
        await model.refresh()
        guard case let .failed(message) = model.state else {
            Issue.record("取得の失敗が状態に出ていない: \(model.state)")
            return
        }
        #expect(!message.contains("github_pat_secret"))
    }

    @Test func refreshIfStaleSkipsRecentRefresh() async throws {
        let model = LoopStatusModel.sample()
        await model.refreshIfStale()
        let lastRefreshed = try #require(model.lastRefreshed)

        await model.refreshIfStale(now: lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval - 1))
        #expect(model.lastRefreshed == lastRefreshed)

        await model.refreshIfStale(now: lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval))
        #expect(try #require(model.lastRefreshed) > lastRefreshed)
    }

    /// 担当の印のある 1 リポジトリを返す取得元
    private struct OneRepositorySource: LoopStatusSource {
        func loopStatusRepositories(org: String) async throws -> [LoopStatusRepository] {
            [LoopStatusRepository(repository: "o/r", heartbeatDescription: OrchestratorHeartbeat.description(at: .now), issues: [])]
        }
    }

    /// 「上限で待機中」の取得が終わらない受信箱の取得元（打ち切られると `CancellationError` を投げる）
    private struct HangingUsageLimitSource: InboxSource {
        func subjectsNeedingAnswer(org: String) async throws -> [InboxSubject] {
            []
        }

        func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
            []
        }

        func lowPriorityIssues(org: String) async throws -> [InboxIssue] {
            []
        }

        func usageLimitedRepositories(org: String, now: Date) async throws -> [UsageLimitedRepository] {
            try await Task.sleep(for: .seconds(60))
            return []
        }
    }

    @Test func cancelledRefreshDoesNotOverwriteWithPartialResults() async throws {
        let hangs = OSAllocatedUnfairLock(initialState: false)
        let model = LoopStatusModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeSource: { _ in hangs.withLock { $0 } ? OneRepositorySource() as any LoopStatusSource : EmptySource() },
            makeInboxSource: { _ in
                hangs.withLock { $0 } ? HangingUsageLimitSource() as any InboxSource : SectionsSource(waiting: [], usageLimited: [])
            }
        )
        await model.refresh()
        let lastRefreshed = model.lastRefreshed
        hangs.withLock { $0 = true }

        // 上限の取得は `try?` で失敗を許すが、打ち切りでは途中の結果（新しい行・空の上限）で一覧を上書きしない
        let task = Task { await model.refresh() }
        while model.state != .loading {
            await Task.yield()
        }
        task.cancel()
        await task.value

        #expect(model.state == .loaded)
        #expect(model.rows.isEmpty)
        #expect(model.lastRefreshed == lastRefreshed)
    }
}
