@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

@MainActor
struct LoopStatusModelTests {
    private struct FailingSource: LoopStatusSource {
        func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
            throw GitHubError.http(status: 401, message: nil)
        }
    }

    private struct EmptySource: LoopStatusSource {
        func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
            []
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

    static func model(
        token: String? = "sample",
        rows: any LoopStatusSource = EmptySource(),
        sections: any InboxSource,
        finalInstructions: any ManualLoopFinalInstructionsChecking = RecordingFinalInstructions()
    ) -> LoopStatusModel {
        LoopStatusModel(
            tokenStore: InMemoryTokenStore(token: token),
            makeSource: { _ in rows },
            makeInboxSource: { _ in sections },
            makeTrust: { _ in TrustedAuthors.default },
            makeStarter: { _ in SampleLoopStarter() },
            makeFinalInstructions: { _, _ in finalInstructions }
        )
    }

    @Test func loadsSampleRowsCoveringEveryStatus() async {
        let model = LoopStatusModel.sample()
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.rows.count == 13)
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

    @Test func loadsSampleLoopsRunningInSameRepository() async {
        let model = LoopStatusModel.sample()
        await model.refresh()
        let now = Date()
        func items(_ name: String) -> [LoopStatusLoopItem] {
            model.rows.first { $0.repository.hasSuffix("/\(name)") }.map(model.loopItems(of:)) ?? []
        }
        // 自動ループと手動ループ 2 つ（pair-quiz-ios）・手動ループ 2 つ（story-maker）は、リポジトリの見出しの下にループを並べる
        let mine = LoopMode.manual(assignee: TrustedAuthors.defaultLogins[0])
        #expect(items("pair-quiz-ios").map(\.mode) == [.automatic, .manual(assignee: "partner"), mine])
        #expect(items("pair-quiz-ios").map { $0.display(now: now).statusText } == ["実行中", "回答待ち", "完了（最終 PR のマージ待ち）"])
        #expect(items("story-maker").map(\.mode) == [.manual(assignee: TrustedAuthors.defaultLogins[0]), .manual(assignee: "partner")])
        // 完了した epic と次に起動した Discussion の自動ループも、Discussion ごとに並べる
        #expect(items("focus-timer-ios").map(\.mode) == [.automatic, .automatic])
        #expect(items("focus-timer-ios").map { $0.display(now: now).statusText } == ["完了（最終 PR のマージ待ち）", "実行中"])
        // ループが 1 つのリポジトリは、今までどおり 1 行
        #expect(items("ask-hub-apple").isEmpty)
        // サンプルの異常（異常終了・長く動きが無い・担当 PC なしの進行中の epic）はループごとに数え、並べたループには異常が無い
        #expect(model.abnormalCount(now: now) == 3)
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

    @Test func keepsBuildHostsFromTrustedIssue() async {
        struct HostsSource: LoopStatusSource {
            func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
                let report = BuildHostsReport(hosts: [BuildHost(name: "macbookpro-m4max", state: .ok)], checkedAt: .now)
                let issue = LoopStatusIssue(
                    number: 9,
                    url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/9")!,
                    author: "mrs1669",
                    updatedAt: .now,
                    body: report.issueBody
                )
                let repository = LoopStatusRepository(
                    repository: "shilokuma-inc/ask-hub-apple", heartbeatDescription: nil, issues: [], buildHostsIssues: [issue]
                )
                return [repository]
            }
        }
        let model = Self.model(rows: HostsSource(), sections: SectionsSource(waiting: [], usageLimited: []))
        await model.refresh()
        #expect(model.buildHosts?.report.hosts.map(\.name) == ["macbookpro-m4max"])
        #expect(model.buildHosts?.repository == "shilokuma-inc/ask-hub-apple")
    }

    @Test func sampleShowsBuildHostsAndMoves() async {
        let model = Self.model(rows: SampleLoopStatusSource(), sections: SampleInboxSource())
        await model.refresh()
        let hosts = model.buildHosts?.hostDisplays ?? []
        #expect(hosts.map(\.tone) == [.available, .unavailable, .idle])
        #expect(hosts.first?.jobTexts.isEmpty == false)
        // 成功と失敗の移動が 1 件ずつ、新しい順
        #expect(model.buildMoves(now: .now).map(\.succeeded) == [true, false])
        #expect(!model.isEmpty)
        // 設定画面の「ビルドの Mac」の入口に出す要約
        #expect(model.buildHosts?.summaryText(now: .now) == "3 台・実行中 1")
        // 実行中のビルドが無い・30 分以上書き直されていない
        let idle = BuildHostsStatus(
            repository: "o/r",
            issueURL: URL(string: "https://github.com/o/r/issues/1")!,
            report: BuildHostsReport(hosts: [BuildHost(name: "m1", state: .ok)], checkedAt: Date(timeIntervalSinceNow: -31 * 60))
        )
        #expect(idle.summaryText(now: .now) == "1 台（古い）")
    }

    @Test func doesNotCountBuildTroubleAsAbnormal() async {
        // 切断の Mac・別の Mac への移動・失敗したビルドは、バッジ（異常の件数）に数えない（Q7。表示だけ）
        struct TroubleSource: LoopStatusSource {
            func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
                let failed = LoopStatusBuild(
                    slot: "a",
                    action: "build",
                    host: "local",
                    moves: [LoopStatusBuildMove(from: "macbookpro-m1pro", to: "local", reason: .disconnected)],
                    exitCode: 65,
                    finishedAt: .now
                )
                let report = LoopStatusReport(
                    state: .running, lastActivityAt: .now, checkedAt: .now, builds: LoopStatusBuilds(latest: [failed], moved: [failed])
                )
                let down = BuildHost(name: "macbookpro-m1pro", state: .down, reason: .disconnected)
                let hosts = BuildHostsReport(hosts: [down], checkedAt: .now)
                let url = URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/1")!
                let repository = LoopStatusRepository(
                    repository: "shilokuma-inc/ask-hub-apple",
                    heartbeatDescription: OrchestratorHeartbeat.description(at: .now),
                    issues: [LoopStatusIssue(number: 1, url: url, author: "mrs1669", updatedAt: .now, body: report.issueBody)],
                    buildHostsIssues: [LoopStatusIssue(number: 2, url: url, author: "mrs1669", updatedAt: .now, body: hosts.issueBody)]
                )
                return [repository]
            }
        }
        let model = Self.model(rows: TroubleSource(), sections: SectionsSource(waiting: [], usageLimited: []))
        await model.refresh()
        #expect(model.buildMoves(now: .now).count == 1)
        #expect(model.buildHosts?.report.hosts.first?.state == .down)
        #expect(model.abnormalCount(now: .now) == 0)
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
            makeInboxSource: { _ in SampleInboxSource() },
            makeTrust: { _ in TrustedAuthors.default },
            makeStarter: { _ in SampleLoopStarter() },
            makeFinalInstructions: { _, _ in SampleManualLoopFinalInstructions() }
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
        func loopStatusRepositories(orgs: [String]) async throws -> [LoopStatusRepository] {
            [LoopStatusRepository(repository: "o/r", heartbeatDescription: OrchestratorHeartbeat.description(at: .now), issues: [])]
        }
    }

    /// 「上限で待機中」の取得が終わらない受信箱の取得元（打ち切られると `CancellationError` を投げる）
    private struct HangingUsageLimitSource: InboxSource {
        func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
            []
        }

        func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
            []
        }

        func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
            []
        }

        func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
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
            },
            makeTrust: { _ in TrustedAuthors.default },
            makeStarter: { _ in SampleLoopStarter() },
            makeFinalInstructions: { _, _ in SampleManualLoopFinalInstructions() }
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

/// 「上限で待機中」「ループの開始待ち」だけを返す受信箱の取得元。`nil` の取得は失敗させる
struct SectionsSource: InboxSource {
    var waiting: [WaitingDiscussion]?
    var usageLimited: [UsageLimitedRepository]?
    var manualLoops: [ManualLoopRecord] = []

    func manualLoopRecords(orgs: [String]) async throws -> [ManualLoopRecord] {
        manualLoops
    }

    func subjectsNeedingAnswer(orgs: [String]) async throws -> [InboxSubject] {
        []
    }

    func questionThreads(of subject: InboxSubject) async throws -> [QuestionThread] {
        []
    }

    func lowPriorityIssues(orgs: [String]) async throws -> [InboxIssue] {
        []
    }

    func waitingDiscussions(orgs: [String]) async throws -> [WaitingDiscussion] {
        guard let waiting else {
            throw GitHubError.http(status: 502, message: nil)
        }
        return waiting
    }

    func usageLimitedRepositories(orgs: [String], now: Date) async throws -> [UsageLimitedRepository] {
        guard let usageLimited else {
            throw GitHubError.http(status: 502, message: nil)
        }
        return usageLimited
    }
}
