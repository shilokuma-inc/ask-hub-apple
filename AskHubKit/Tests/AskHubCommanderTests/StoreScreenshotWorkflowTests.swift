@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import os
import Testing

/// GitHub の代わりの、撮影のワークフローの起動と実行
struct FakeWorkflows {
    /// 起動したワークフロー
    struct Dispatch: Equatable {
        var workflow: String
        var ref: String
        var inputs: [String: String]
    }

    var dispatches: [Dispatch] = []
    /// この入力を送ると、呼ぶ側のワークフローに無い入力として 422 で断る（app-kit の古い版）
    var rejectedInputs: Set<String> = []
    /// 起動の応答（既定は実行 44900000101）
    var dispatchReply: Result<DispatchedRun?, PullRequestError> = .success(
        DispatchedRun(id: 44_900_000_101, url: URL(string: "https://github.com/\(ReleaseWatchTests.repo)/actions/runs/44900000101"))
    )
    /// id → 実行の様子
    var runs: [Int: WorkflowRunDetail] = [:]
    var runReads = 0
    /// ブランチの workflow_dispatch の実行の一覧
    var dispatchedRuns: [WorkflowRunDetail] = []
    /// 決めると、実行の一覧を読めずにこれを投げる
    var dispatchedRunsFailure: PullRequestError?
    var cancelledRuns: [Int] = []
    /// 取り消しの応答
    var cancelReply: Result<Void, PullRequestError> = .success(())
    /// 実行の id → artifact
    var artifacts: [Int: [RunArtifact]] = [:]
    /// artifact の id → zip（`FakeArtifactExtractor.zip` の形）
    var zips: [Int: Data] = [:]
    /// artifact の一覧を読んだ数と、決めると一覧を読めずにこれを投げる
    var artifactReads = 0
    var artifactsFailure: PullRequestError?
}

extension FakeReleaseHosting {
    func runArtifacts(_ repo: RepositoryFullName, runID: Int) async throws(PullRequestError) -> [RunArtifact] {
        let (artifacts, failure) = workflows.withLock { state in
            state.artifactReads += 1
            return (state.artifacts[runID] ?? [], state.artifactsFailure)
        }
        if let failure { throw failure }
        return artifacts
    }

    func downloadArtifact(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) -> Data {
        guard let zip = workflows.withLock({ $0.zips[id] }) else { throw .notFound }
        return zip
    }

    func dispatchWorkflow(
        _ repo: RepositoryFullName,
        workflow: String,
        ref: String,
        inputs: [String: String]
    ) async throws(PullRequestError) -> DispatchedRun? {
        let reply = workflows.withLock { state in
            state.dispatches.append(.init(workflow: workflow, ref: ref, inputs: inputs))
            guard Set(inputs.keys).isDisjoint(with: state.rejectedInputs) else {
                return Result<DispatchedRun?, PullRequestError>.failure(.rejected(message: "Unexpected inputs provided"))
            }
            return state.dispatchReply
        }
        return try reply.get()
    }

    func workflowRun(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) -> WorkflowRunDetail {
        let run = workflows.withLock { state in
            state.runReads += 1
            return state.runs[id]
        }
        guard let run else { throw .notFound }
        return run
    }

    func dispatchedRuns(
        _ repo: RepositoryFullName,
        workflow: String,
        branch: String
    ) async throws(PullRequestError) -> [WorkflowRunDetail] {
        let (runs, failure) = workflows.withLock { ($0.dispatchedRuns, $0.dispatchedRunsFailure) }
        if let failure { throw failure }
        return runs
    }

    func cancelWorkflowRun(_ repo: RepositoryFullName, id: Int) async throws(PullRequestError) {
        let reply = workflows.withLock { state in
            state.cancelledRuns.append(id)
            return state.cancelReply
        }
        try reply.get()
    }
}

/// リポジトリの撮影のワークフローで撮る App Store のスクショ（`capture: actions`）: 起動して見張る
extension ReleaseWatchTests {
    static let screenshotRun = 44_900_000_101
    static let releaseBranch = "release/1.2.0"
    static let releaseHead = String(repeating: "d", count: 40)

    func addWorkflowScreenshotRepository() async throws {
        var file = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        file.build = RepositoryFile.Build(
            xcode: try BuildSettings(project: "OshiCon.xcodeproj", scheme: "OshiCon", destinations: [.macOS]),
            childChecks: ["build / build"],
            finalChecks: ["build / build"],
            storeScreenshots: .actions(StoreScreenshotWorkflow(
                workflow: "app-store-screenshots.yml",
                artifacts: [Self.iPhone: "APP_IPHONE_67", Self.duo: "APP_IPHONE_DUO"],
                languages: ["ja": .init(language: "ja"), "en-US": .init(language: "en")],
                baseLocale: "ja"
            ))
        )
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
    }

    func screenshotRun(
        id: Int = screenshotRun,
        status: String = "in_progress",
        conclusion: String? = nil,
        branch: String = releaseBranch,
        sha: String = releaseHead,
        createdAt: Date = now
    ) -> WorkflowRunDetail {
        WorkflowRunDetail(
            id: id,
            status: status,
            conclusion: conclusion,
            event: "workflow_dispatch",
            path: ".github/workflows/app-store-screenshots.yml",
            headBranch: branch,
            headSHA: sha,
            createdAt: createdAt,
            url: URL(string: "https://github.com/\(Self.repo)/actions/runs/\(id)")
        )
    }

    @Test func dispatchesTheScreenshotWorkflowOnTheReleaseBranch() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        let watch = watch()
        await watch.refresh()

        let file = try await submission()
        let shots = try #require(file.screenshots)
        #expect(shots.state == .capturing && shots.commit == Self.developHead)
        #expect(shots.run?.id == Self.screenshotRun && shots.run?.dispatchedAt == Timestamp(Self.now))
        #expect(shots.run?.url == "https://github.com/shariverse/oshikatsu-countdown-ios/actions/runs/44900000101")
        // 反映はしない（upload: false）。撮る表示サイズは artifacts の値
        let dispatches = hosting.workflows.withLock { $0.dispatches }
        let expected = FakeWorkflows.Dispatch(
            workflow: "app-store-screenshots.yml",
            ref: Self.releaseBranch,
            inputs: ["upload": "false", "display_types": "APP_IPHONE_67,APP_IPHONE_DUO"]
        )
        #expect(dispatches == [expected])
        // 撮っている間は審査に出す準備がそろわない
        #expect(!file.isPrepared)
        // UI テストの道具は使わない
        #expect(await watch.capturing.isEmpty)
    }

    @Test func watchesTheRunEveryFiveMinutesAndWritesOnlyChanges() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        let watch = watch()
        await watch.refresh()
        hosting.workflows.withLock { $0.runs[Self.screenshotRun] = screenshotRun(status: "queued") }

        // 起動した直後は読まない
        clock.advance(minutes: 2)
        await watch.refresh()
        #expect(hosting.workflows.withLock { $0.runReads } == 0)

        clock.advance(minutes: 3)
        await watch.refresh()
        var file = try await submission()
        #expect(hosting.workflows.withLock { $0.runReads } == 1)
        #expect(file.screenshots?.run?.status == "queued" && file.screenshots?.state == .capturing)
        let written = file.updatedAt

        // 様子が変わらなければ書かない
        clock.advance(minutes: 5)
        await watch.refresh()
        file = try await submission()
        #expect(hosting.workflows.withLock { $0.runReads } == 2)
        #expect(file.updatedAt == written)

        hosting.workflows.withLock { $0.runs[Self.screenshotRun] = screenshotRun(status: "in_progress", sha: Self.releaseHead) }
        clock.advance(minutes: 5)
        await watch.refresh()
        file = try await submission()
        // 実行が撮ったコミット（release ブランチが進んでいれば、その先頭）を記録する
        #expect(file.screenshots?.run?.status == "in_progress" && file.screenshots?.commit == Self.releaseHead)
    }

    @Test func importsWhenTheRunCompletes() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        let watch = watch(screenshots: FakeStoreScreenshots())
        await watch.refresh()
        let revision = try await submission().revision
        hosting.workflows.withLock {
            $0.runs[Self.screenshotRun] = screenshotRun(status: "completed", conclusion: "success")
        }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForScreenshotCaptures()

        let shots = try #require(try await submission().screenshots)
        // 終わったので取り込んだ。この版の配信中の版には配置のスクショが無いので、比べられずに failed（スクショを変えずに審査に出せる）
        #expect(shots.state == .failed && shots.failure?.contains("App Asset Library") == true)
        #expect(shots.run?.status == "completed" && shots.run?.conclusion == "success")
        #expect(try await submission().revision > revision)
        #expect(await watch.screenshotRunsCheckedAt.isEmpty)
    }

    @Test func failsWhenTheRunIsCancelled() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        let watch = watch()
        await watch.refresh()
        hosting.workflows.withLock {
            $0.runs[Self.screenshotRun] = screenshotRun(status: "completed", conclusion: "cancelled")
        }
        clock.advance(minutes: 5)
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .failed && shots.failure?.contains("cancelled") == true)
    }

    @Test func failsWhenTheWorkflowIsMissing() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        hosting.workflows.withLock { $0.dispatchReply = .failure(.notFound) }
        let watch = watch()
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        // 送り直しても直らないので、スクショを変えずに審査に出せるようにする
        #expect(shots.state == .failed && shots.failure?.contains("GitHub に無い") == true)
        #expect(shots.run?.id == nil)
    }

    @Test func dispatchesAgainAfterATransientFailure() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        hosting.workflows.withLock { $0.dispatchReply = .failure(.serverError(status: 502)) }
        let watch = watch()
        await watch.refresh()
        var file = try await submission()
        #expect(file.screenshots?.state == .capturing && file.screenshots?.run?.id == nil)
        #expect(file.problem?.step == .screenshots && file.problem?.needsHuman == false)

        hosting.workflows.withLock { $0.dispatchReply = .success(DispatchedRun(id: Self.screenshotRun, url: nil)) }
        // 5 分たつまでは、一覧から探すだけで送り直さない
        clock.advance(minutes: 5)
        await watch.refresh()
        file = try await submission()
        #expect(hosting.workflows.withLock { $0.dispatches.count } == 2)
        #expect(file.screenshots?.run?.id == Self.screenshotRun)
        #expect(file.screenshots?.run?.dispatchedAt == Timestamp(clock.now))
    }

    @Test func findsTheRunWhenTheDispatchReturnsNoID() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        // 起動の前から、人が起動した実行がある（直前の 1 秒前に作られたものも）
        let before = [
            screenshotRun(id: 44_900_000_090, createdAt: Self.now.addingTimeInterval(-3_600)),
            screenshotRun(id: 44_900_000_095, status: "completed", conclusion: "success", createdAt: Self.now.addingTimeInterval(-1))
        ]
        hosting.workflows.withLock { state in
            state.dispatchReply = .success(nil)
            state.dispatchedRuns = before
        }
        let watch = watch()
        await watch.refresh()
        let marked = try #require(try await submission().screenshots?.run)
        #expect(marked.id == nil && marked.after == 44_900_000_095)

        hosting.workflows.withLock { state in
            // ほかのブランチの実行は使わない。起動の前からあった実行（after 以下）も使わない
            state.dispatchedRuns = before + [
                screenshotRun(id: 44_900_000_099, branch: "release/1.1.0", createdAt: Self.now.addingTimeInterval(10)),
                screenshotRun(id: Self.screenshotRun, status: "queued", createdAt: Self.now.addingTimeInterval(3))
            ]
        }
        clock.advance(minutes: 5)
        await watch.refresh()
        let run = try #require(try await submission().screenshots?.run)
        #expect(run.id == Self.screenshotRun && run.status == "queued" && run.after == 44_900_000_095)
        #expect(run.dispatchedAt == Timestamp(Self.now))
        #expect(hosting.workflows.withLock { $0.dispatches.count } == 1)
    }

    @Test func doesNotGuessWhenAnotherRunStartedAfterTheDispatch() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        hosting.workflows.withLock { $0.dispatchReply = .success(nil) }
        let watch = watch()
        await watch.refresh()
        hosting.workflows.withLock { state in
            // 起動の後に、人も同じワークフローを起動した
            state.dispatchedRuns = [
                screenshotRun(id: Self.screenshotRun, status: "queued", createdAt: Self.now.addingTimeInterval(3)),
                screenshotRun(id: 44_900_000_102, status: "queued", createdAt: Self.now.addingTimeInterval(4))
            ]
        }
        clock.advance(minutes: 5)
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        #expect(shots.state == .failed && shots.failure?.contains("見分けられない") == true && shots.run?.id == nil)
        #expect(hosting.workflows.withLock { $0.dispatches.count } == 1)
    }

    @Test func cancelsTheRunAfterSixHours() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        let watch = watch()
        await watch.refresh()
        hosting.workflows.withLock { $0.runs[Self.screenshotRun] = screenshotRun(status: "queued") }
        clock.advance(minutes: 6 * 60)
        await watch.refresh()
        let shots = try #require(try await submission().screenshots)
        #expect(hosting.workflows.withLock { $0.cancelledRuns } == [Self.screenshotRun])
        #expect(shots.state == .failed && shots.failure?.contains("6 時間") == true)
    }

    @Test func keepsWatchingWhenTheCancelFailsForAWhile() async throws {
        try await startRelease()
        try await addWorkflowScreenshotRepository()
        let watch = watch()
        await watch.refresh()
        hosting.workflows.withLock { state in
            state.runs[Self.screenshotRun] = screenshotRun(status: "in_progress")
            state.cancelReply = .failure(.serverError(status: 502))
        }
        clock.advance(minutes: 6 * 60)
        await watch.refresh()
        // 取り消せなかったので、撮っている印のまま次の見回りで取り消し直す（実行を動かしたまま終えない）
        var file = try await submission()
        #expect(file.screenshots?.state == .capturing && file.problem?.needsHuman == false)

        hosting.workflows.withLock { $0.cancelReply = .success(()) }
        clock.advance(minutes: 5)
        await watch.refresh()
        file = try await submission()
        #expect(hosting.workflows.withLock { $0.cancelledRuns } == [Self.screenshotRun, Self.screenshotRun])
        #expect(file.screenshots?.state == .failed && file.screenshots?.failure?.contains("取り消した") == true)
    }

    @Test func screenshotInputsJoinTheArtifactNames() {
        let workflow = StoreScreenshotWorkflow(
            workflow: "app-store-screenshots.yml",
            artifacts: [Self.iPhone: "APP_IPHONE_67", Self.duo: "APP_IPHONE_DUO", "IPHONE_OTHER_PROFILE": "APP_IPHONE_67"],
            languages: ["ja": .init(language: "ja")],
            baseLocale: "ja"
        )
        #expect(ReleaseWatch.screenshotInputs(workflow) == ["upload": "false", "display_types": "APP_IPHONE_67,APP_IPHONE_DUO"])
    }
}
