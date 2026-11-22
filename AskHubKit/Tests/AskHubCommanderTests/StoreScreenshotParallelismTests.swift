@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

/// 撮影のワークフローで同時に使う macOS ランナーの数（`max_parallel`）
extension ReleaseWatchTests {
    /// 日本時間の 2026-11-18 03:00（夜間）。`now` は 20:06（ふだん）
    static let night = Date(timeIntervalSince1970: 1_794_938_400)
    static let sibling = RepositoryFullName(rawValue: "shariverse/deki-roulette-ios")!
    static let stranger = RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!

    /// app-kit を入れ、撮影のワークフローで撮るリポジトリ
    func addParallelScreenshotRepository(appKit: String? = "v1.1.0", workflow: String = "app-store-screenshots.yml") async throws {
        try await addWorkflowScreenshotRepository()
        var file = try StateFileCoder.decode(RepositoryFile.self, from: try #require(await store.data(at: StatePath.repository(Self.repo))))
        if case let .actions(settings)? = file.build?.storeScreenshots {
            var settings = settings
            settings.workflow = workflow
            file.build?.storeScreenshots = .actions(settings)
        }
        file.appKit = appKit.map { .init(ref: String(repeating: "1", count: 40), version: AppKitVersion(rawValue: $0)) }
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
    }

    func repositoryFile() async throws -> RepositoryFile {
        try StateFileCoder.decode(RepositoryFile.self, from: try #require(await store.data(at: StatePath.repository(Self.repo))))
    }

    /// 撮影の実行が動いているリリースの記録
    func capturingSubmission(_ repo: RepositoryFullName, status: String? = "in_progress") -> SubmissionFile {
        var file = SubmissionHandlersTests.started()
        file.repo = repo
        let now = Timestamp(Self.now)
        file.screenshots = .init(state: .capturing, startedAt: now, run: .init(id: 44_900_000_900, dispatchedAt: now, status: status))
        return file
    }

    func epicJob(_ repo: RepositoryFullName, state: JobState) -> JobFile {
        let now = Timestamp(Self.now)
        return JobFile(
            id: ULID(rawValue: "01JCJ0B0000000000000000001")!,
            kind: .implementTask,
            repo: repo,
            epic: ULID(rawValue: "01JCEP1C000000000000000001")!,
            needs: .init(claude: true, build: true),
            state: state,
            createdAt: now,
            updatedAt: now
        )
    }

    func lastMaxParallel() -> String? {
        hosting.workflows.withLock { $0.dispatches.last?.inputs["max_parallel"] }
    }

    /// 数の決め方の場面
    struct ParallelismCase {
        var otherRuns = 0
        var refreshed = true
        var epicJobs: Bool? = false
        var now: Date
        var count: Int
    }

    /// 撮影のワークフローの設定の場面
    struct WorkflowCase {
        var appKit: String?
        var workflow = "app-store-screenshots.yml"
        var accepts: Bool
    }

    @Test func decidesHowManyRunnersToUse() {
        let day = Self.now
        let cases: [ParallelismCase] = [
            .init(refreshed: false, now: Self.night, count: 1),
            .init(otherRuns: 1, now: Self.night, count: 1),
            .init(otherRuns: 2, epicJobs: nil, now: day, count: 1),
            .init(now: Self.night, count: 5),
            .init(epicJobs: true, now: Self.night, count: 3),
            .init(epicJobs: nil, now: Self.night, count: 3),
            .init(now: day, count: 3),
            // 日本時間の 0:00 と 6:59:59 は夜間、7:00 は夜間でない
            .init(now: Date(timeIntervalSince1970: 1_794_927_600), count: 5),
            .init(now: Date(timeIntervalSince1970: 1_794_952_799), count: 5),
            .init(now: Date(timeIntervalSince1970: 1_794_952_800), count: 3)
        ]
        for item in cases {
            let decided = ReleaseWatch.screenshotParallelism(
                otherRuns: item.otherRuns, refreshed: item.refreshed, epicJobs: item.epicJobs, now: item.now
            )
            #expect(decided.count == item.count, "\(item) → \(decided)")
        }
    }

    @Test func sendsMaxParallelOnlyToTheAppKitWorkflowFromV110() async throws {
        let cases: [WorkflowCase] = [
            .init(appKit: "v1.1.0", accepts: true),
            .init(appKit: "v2.0.0", accepts: true),
            .init(appKit: "v1.0.1", accepts: false),
            .init(appKit: nil, accepts: false),
            .init(appKit: "v1.1.0", workflow: "screenshots.yml", accepts: false)
        ]
        for item in cases {
            try await addParallelScreenshotRepository(appKit: item.appKit, workflow: item.workflow)
            let file = try await repositoryFile()
            guard case let .actions(workflow)? = file.build?.storeScreenshots else {
                Issue.record("撮影のワークフローの設定が無い")
                return
            }
            #expect(ReleaseWatch.acceptsMaxParallel(file, workflow: workflow) == item.accepts, "\(item)")
        }
    }

    @Test func sendsOneUntilTheFirstRoundThenUsesTheSameRuleForRetakes() async throws {
        try await startRelease()
        try await addParallelScreenshotRepository()
        let watch = watch()
        // 起動し直した直後の周は、ほかの撮影が動いているか分からないので 1 本
        await watch.refresh()
        #expect(lastMaxParallel() == "1")
        #expect(await watch.screenshotRunsInFlight == ["\(Self.repo.rawValue)/\(Self.next.rawValue)": "shariverse"])

        // 撮り直しも同じ決め方。一周した後のふだんの時間は 3 本（自分の撮影は数えない）
        try await requestRetake()
        prepareSecondRun()
        clock.advance(minutes: 1)
        await watch.refresh()
        let dispatches = hosting.workflows.withLock { $0.dispatches }
        #expect(dispatches.count == 2 && dispatches.last?.inputs["max_parallel"] == "3")
        #expect(dispatches.last?.inputs["display_types"] == "APP_IPHONE_67,APP_IPHONE_DUO")
    }

    @Test func doesNotSendMaxParallelToOlderWorkflows() async throws {
        try await startRelease()
        try await addParallelScreenshotRepository(appKit: "v1.0.1")
        await watch().refresh()
        let dispatches = hosting.workflows.withLock { $0.dispatches }
        #expect(dispatches.count == 1 && dispatches.first?.inputs["max_parallel"] == nil)
    }

    @Test func usesOneRunnerWhileAnotherAppInTheSameOwnerIsCapturing() async throws {
        try await addParallelScreenshotRepository()
        let watch = watch()
        await watch.refresh()
        let settings = try await repositoryFile()
        guard case let .actions(workflow)? = settings.build?.storeScreenshots else {
            Issue.record("撮影のワークフローの設定が無い")
            return
        }
        let mine = SubmissionHandlersTests.started()
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 3)

        // 同じ持ち主（大文字と小文字は区別しない）のほかのアプリが撮っている
        let sibling = capturingSubmission(RepositoryFullName(rawValue: "Shariverse/deki-roulette-ios")!)
        await watch.noteScreenshotRuns(sibling.repo, files: [sibling], unreadable: [])
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 1)

        // 記録を読めなかった版は、分からないので覚えたものを残す
        await watch.noteScreenshotRuns(sibling.repo, files: [], unreadable: [sibling.version])
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 1)

        // 撮り終えた（取り込み待ちは macOS のランナーを使わない）
        await watch.noteScreenshotRuns(sibling.repo, files: [capturingSubmission(sibling.repo, status: "completed")], unreadable: [])
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 3)

        // ほかの持ち主の撮影は数えない（枠は持ち主ごと）
        let stranger = capturingSubmission(Self.stranger)
        await watch.noteScreenshotRuns(Self.stranger, files: [stranger], unreadable: [])
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 3)

        // 見回りの対象から外れたリポジトリの覚えたものは、周の終わりに消す
        await watch.noteScreenshotRuns(Self.sibling, files: [capturingSubmission(Self.sibling)], unreadable: [])
        await watch.refresh()
        #expect(await watch.screenshotRunsInFlight.isEmpty)
    }

    @Test func usesFiveRunnersAtNightOnlyWithoutEpicJobsInTheSameOwner() async throws {
        try await addParallelScreenshotRepository()
        let watch = watch()
        clock.advance(minutes: 414)
        await watch.refresh()
        let settings = try await repositoryFile()
        guard case let .actions(workflow)? = settings.build?.storeScreenshots else {
            Issue.record("撮影のワークフローの設定が無い")
            return
        }
        let mine = SubmissionHandlersTests.started()
        // epic のジョブが動いているか、まだ司令塔の周から受け取っていない
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 3)

        await watch.noteEpicJobs([])
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 5)

        await watch.noteEpicJobs([epicJob(Self.sibling, state: .running)])
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 3)

        // 人を待つ・止めたジョブと、ほかの持ち主のジョブは数えない
        await watch.noteEpicJobs([
            epicJob(Self.sibling, state: .waitingHuman), epicJob(Self.sibling, state: .paused), epicJob(Self.stranger, state: .running)
        ])
        #expect(await watch.screenshotParallelism(for: mine, settings: settings, workflow: workflow)?.count == 5)
    }

    @Test func retriesWithoutMaxParallelWhenTheWorkflowRejectsIt() async throws {
        try await startRelease()
        try await addParallelScreenshotRepository()
        hosting.workflows.withLock { $0.rejectedInputs = ["max_parallel"] }
        await watch().refresh()

        // 記録の版がずれていて（呼ぶ側に max_parallel が無い）422 で断られたら、外して 1 回だけ送り直す
        let dispatches = hosting.workflows.withLock { $0.dispatches }
        #expect(dispatches.map { $0.inputs["max_parallel"] } == ["1", nil])
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .capturing && shots.run?.id == Self.screenshotRun)
    }
}
