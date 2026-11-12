@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import os
import Testing

/// 決めたアプリと配信中の版を返し、読んだ回数を数える
final class FakeAppStore: AppStoreConnectReading {
    struct State {
        var apps: [AppStoreApp] = []
        var versions: [LiveAppVersion] = []
        var reads = 0
    }

    let keyID = "ABCDE12345"
    let state = OSAllocatedUnfairLock(initialState: State())

    func apps(bundleIDs: [String]) async throws(AppStoreConnectError) -> [AppStoreApp] {
        state.withLock { $0.apps.filter { bundleIDs.contains($0.bundleId) } }
    }

    func liveVersions(of appID: String) async throws(AppStoreConnectError) -> [LiveAppVersion] {
        state.withLock { state in
            state.reads += 1
            return state.versions
        }
    }
}

/// 決めた Bundle ID・版のファイル・変更を返す
final class FakeReleaseSources: ReleaseSourceReading {
    struct State {
        var bundleIDs = ["jp.shilokuma.OshiCon"]
        var snapshot = MarketingVersionSnapshot(
            head: ReleaseWatchTests.developHead,
            tree: ReleaseWatchTests.developTree,
            files: [
                .init(
                    path: "Configs/Project.xcconfig",
                    content: "APP_BUNDLE_IDENTIFIER = jp.shilokuma.OshiCon\nMARKETING_VERSION = 1.1.0\n"
                )
            ]
        )
        var changes = ReleaseChanges(
            previousTag: "v1.0.0",
            changes: [.init(commit: ReleaseWatchTests.epicMerge, pullRequest: 150, title: "写しを切り抜く")]
        )
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    func bundleIdentifiers(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> [String] {
        state.withLock { $0.bundleIDs }
    }

    func marketingVersions(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> MarketingVersionSnapshot {
        state.withLock { $0.snapshot }
    }

    func changes(
        _ repo: RepositoryFullName,
        upTo commit: String,
        below version: MarketingVersion
    ) async throws(WorkspaceError) -> ReleaseChanges {
        state.withLock { $0.changes }
    }

    func prepare(_ repo: RepositoryFullName, commit: String, for id: ULID) async throws(WorkspaceError) -> PreparedWorkspace {
        PreparedWorkspace(directory: URL(fileURLWithPath: "/tmp"), facts: "")
    }

    func release(_ id: ULID) async {}
}

/// GitHub の代わり。決めた実行・タグ・Release・PR を返し、作ったものを残す
final class FakeReleaseHosting: ReleaseHosting {
    struct Committed {
        var branch: String
        var files: [String: String]
        var message: String
    }

    struct State {
        var runs: [ActionsRun] = []
        var tags: [String: String] = [:]
        var tagMessages: [String: String] = [:]
        var releases: [String: String] = [:]
        var committed: [Committed] = []
        var opened: [PullRequestDraft] = []
        var pull: PullRequest?
        var checks = CheckSummary(verdict: .pending)
        var merged: [Int] = []
        var calls = 0
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    private func call<Value: Sendable>(_ body: @Sendable (inout State) -> Value) -> Value {
        state.withLock { state in
            state.calls += 1
            return body(&state)
        }
    }

    func workflowRuns(_ repo: RepositoryFullName, createdFrom from: Date, to: Date) async throws(PullRequestError) -> [ActionsRun] {
        call { $0.runs }
    }

    func tagCommit(_ repo: RepositoryFullName, tag: String) async throws(PullRequestError) -> String? {
        call { $0.tags[tag] }
    }

    func createAnnotatedTag(_ repo: RepositoryFullName, _ tag: AnnotatedTag) async throws(PullRequestError) {
        call { state in
            state.tags[tag.name] = tag.commit
            state.tagMessages[tag.name] = tag.message
        }
    }

    func release(_ repo: RepositoryFullName, tag: String) async throws(PullRequestError) -> PublishedRelease? {
        call { state in
            state.releases[tag].map { _ in PublishedRelease(url: URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!, tag: tag) }
        }
    }

    func publishRelease(_ repo: RepositoryFullName, tag: String, body: String) async throws(PullRequestError) -> PublishedRelease {
        call { state in
            state.releases[tag] = body
            return PublishedRelease(url: URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!, tag: tag)
        }
    }

    func commitFiles(_ repo: RepositoryFullName, _ commit: VersionCommit) async throws(PullRequestError) -> String {
        call { state in
            state.committed.append(Committed(branch: commit.branch, files: commit.files, message: commit.message))
            return String(repeating: "e", count: 40)
        }
    }

    func openPullRequest(_ repo: RepositoryFullName, _ draft: PullRequestDraft) async throws(PullRequestError) -> PullRequest {
        call { state in
            state.opened.append(draft)
            let pull = PullRequest(
                number: 170,
                state: .open,
                merged: false,
                head: (draft.head, String(repeating: "e", count: 40)),
                baseRef: draft.base
            )
            state.pull = pull
            return pull
        }
    }

    func pullRequest(_ repo: RepositoryFullName, number: Int) async throws(PullRequestError) -> PullRequest {
        guard let pull = call({ $0.pull }) else { throw .notFound }
        return pull
    }

    func checks(_ repo: RepositoryFullName, at sha: String, required: Set<String>) async throws(PullRequestError) -> CheckSummary {
        call { $0.checks }
    }

    func merge(_ repo: RepositoryFullName, number: Int, headSHA: String) async throws(PullRequestError) -> MergedPullRequest {
        call { state in
            state.merged.append(number)
            state.pull?.merged = true
            state.pull?.state = .closed
            return MergedPullRequest(sha: nil, mergedNow: true)
        }
    }
}

/// 決めた下書きを返し、受け取った材料を残す
final class FakeNotesDrafter: ReleaseNotesDrafting {
    let materials = OSAllocatedUnfairLock<[ReleaseNotesMaterial]>(initialState: [])

    func draft(_ material: ReleaseNotesMaterial) async throws(ReleaseNotesFailure) -> String {
        materials.withLock { $0.append(material) }
        return "## 新しい機能\n- 写真を切り抜けるようになりました"
    }
}

/// App Store での配信の検知と後作業（`ReleaseWatch`）
struct ReleaseWatchTests {
    static let repo = RepositoryFullName(rawValue: "shariverse/oshikatsu-countdown-ios")!
    static let now = Date(timeIntervalSince1970: 1_795_000_000)
    static let released = String(repeating: "a", count: 40)
    static let developHead = String(repeating: "b", count: 40)
    static let developTree = String(repeating: "c", count: 40)
    static let epicMerge = String(repeating: "f", count: 40)
    static let version = MarketingVersion(rawValue: "1.1.0")!

    let store = InMemoryStateStore()
    let appStore = FakeAppStore()
    let sources = FakeReleaseSources()
    let hosting = FakeReleaseHosting()
    let drafter = FakeNotesDrafter()
    let clock = TestClock(Self.now)

    func watch(stores: [any AppStoreConnectReading]? = nil) -> ReleaseWatch {
        let clock = clock
        return ReleaseWatch(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { clock.now },
            stores: stores ?? [appStore],
            sources: sources,
            hosting: hosting,
            drafter: drafter,
            authors: FixedCommitAuthor(GitAuthor(name: "Takumi", email: "1+mrs1669@users.noreply.github.com")),
            log: { _ in }
        )
    }

    func addRepository() async throws {
        var file = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        file.build = RepositoryFile.Build(
            xcode: try BuildSettings(project: "OshiCon.xcodeproj", scheme: "OshiCon", destinations: [.macOS]),
            childChecks: ["build / build"],
            finalChecks: ["build / build"]
        )
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
    }

    func live(_ platform: AppStorePlatform = .iOS, build: String = "31", uploadedMinutesAgo: Double = 600) {
        appStore.state.withLock { state in
            state.apps = [AppStoreApp(id: "6740000001", bundleId: "jp.shilokuma.OshiCon", name: "推し活カウントダウン")]
            state.versions.append(.init(
                platform: platform,
                version: Self.version,
                build: build,
                uploadedAt: Self.now.addingTimeInterval(-uploadedMinutesAgo * 60)
            ))
        }
    }

    func uploadRun(number: Int = 31, sha: String = released, startedMinutesAgo: Double = 630) -> ActionsRun {
        ActionsRun(
            id: 19_000_000_031,
            runNumber: number,
            path: ReleaseCommitFinder.uploadWorkflow,
            headSHA: sha,
            event: "push",
            startedAt: Self.now.addingTimeInterval(-startedMinutesAgo * 60),
            updatedAt: Self.now.addingTimeInterval(-(startedMinutesAgo - 40) * 60)
        )
    }

    func release() async throws -> ReleaseFile {
        let data = try #require(await store.data(at: StatePath.release(Self.repo, Self.version)))
        return try StateFileCoder.decode(ReleaseFile.self, from: data)
    }

    func put(_ file: ReleaseFile) async throws {
        await store.put(StatePath.release(Self.repo, Self.version), data: try StateFileCoder.encode(file))
    }

    @Test func findsReleaseAndRunsPostWorkUntilNotesReview() async throws {
        try await addRepository()
        live()
        let run = uploadRun()
        hosting.state.withLock { $0.runs = [run] }
        await watch().refresh()

        let file = try await release()
        #expect(file.platforms.map(\.platform) == [.iOS])
        #expect(file.platforms.first?.build == "31")
        #expect(file.commit == .init(sha: Self.released, source: .uploadRun, platform: .iOS, build: "31", run: run.id, runNumber: 31))
        #expect(file.tag?.name == "v1.1.0" && file.tag?.created == true)
        #expect(file.notes?.version == 1 && file.notes?.previousTag == "v1.0.0")
        #expect(file.notes?.draft == "## 新しい機能\n- 写真を切り抜けるようになりました")
        #expect(file.awaitsNotesReview && file.githubRelease == nil)
        #expect(file.nextVersion == .init(
            version: MarketingVersion(rawValue: "1.2.0")!,
            state: .open,
            pullRequest: 170,
            at: Timestamp(Self.now)
        ))
        #expect(file.problem == nil)

        let state = hosting.state.withLock { $0 }
        #expect(state.tags["v1.1.0"] == Self.released)
        #expect(state.tagMessages["v1.1.0"] == "推し活カウントダウン 1.1.0 (31)\n\nApp Store で配信した 1.1.0 のビルド (31) のコミット。\n")
        #expect(state.committed.map(\.branch) == ["askhub/version-1.2.0"])
        #expect(state.committed.first?.files == [
            "Configs/Project.xcconfig": "APP_BUNDLE_IDENTIFIER = jp.shilokuma.OshiCon\nMARKETING_VERSION = 1.2.0\n"
        ])
        #expect(state.committed.first?.message == "[chore] MARKETING_VERSION を 1.2.0 に上げる")
        #expect(state.opened.map(\.title) == ["【CHORE】MARKETING_VERSION を 1.2.0 に上げる"])
        #expect(state.opened.first?.base == "develop" && state.opened.first?.head == "askhub/version-1.2.0")
        let material = try #require(drafter.materials.withLock { $0.first })
        #expect(material.appName == "推し活カウントダウン" && material.commit == Self.released)
    }

    @Test func publishesConfirmedNotesAndMergesNextVersionWhenChecksPass() async throws {
        try await addRepository()
        live()
        hosting.state.withLock { $0.runs = [uploadRun()] }
        let watch = watch()
        await watch.refresh()
        // 人がリリース文を確かめて公開を押した（`PublishGitHubReleaseHandler` が写す）
        var file = try await release()
        let approval = IntentReference(
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!
        )
        file.notes?.confirmed = .init(text: "## 新しい機能\n- 写真を切り抜けます", approval: approval, at: Timestamp(Self.now))
        try await put(file)
        hosting.state.withLock { $0.checks = CheckSummary(verdict: .passed) }

        clock.advance(minutes: 10)
        await watch.refresh()
        file = try await release()
        #expect(file.githubRelease?.url == "https://github.com/shariverse/oshikatsu-countdown-ios/releases/tag/v1.1.0")
        #expect(file.githubRelease?.created == true)
        #expect(file.nextVersion?.state == .merged)
        #expect(file.isFinished)
        #expect(hosting.state.withLock { ($0.releases["v1.1.0"], $0.merged) } == ("## 新しい機能\n- 写真を切り抜けます", [170]))

        // 終わった記録は、もう GitHub を読まない
        let calls = hosting.state.withLock { $0.calls }
        clock.advance(minutes: 10)
        await watch.refresh()
        #expect(hosting.state.withLock { $0.calls } == calls)
    }

    @Test func recordsTagAndReleaseMadeByHandAndSkipsVersionAlreadyAhead() async throws {
        try await addRepository()
        live()
        hosting.state.withLock { state in
            state.tags["v1.1.0"] = Self.released
            state.releases["v1.1.0"] = "手で書いた本文"
        }
        sources.state.withLock { $0.snapshot.files = [.init(path: "Configs/Project.xcconfig", content: "MARKETING_VERSION = 1.2.0\n")] }
        await watch().refresh()

        let file = try await release()
        #expect(file.commit == .init(sha: Self.released, source: .existingTag))
        #expect(file.tag?.created == false)
        #expect(file.githubRelease?.created == false)
        #expect(file.nextVersion?.state == .skipped && file.nextVersion?.version.rawValue == "1.2.0")
        #expect(file.isFinished)
        #expect(drafter.materials.withLock { $0 }.isEmpty)
        #expect(hosting.state.withLock { $0.opened }.isEmpty)
    }

    @Test func leavesProblemForHumanWhenTheUploadIsNotFoundAndDoesNotRewriteIt() async throws {
        try await addRepository()
        live()
        let watch = watch()
        await watch.refresh()
        let file = try await release()
        #expect(file.commit == nil && file.tag == nil)
        #expect(file.problem?.step == .commit && file.problem?.needsHuman == true)
        #expect(file.problem?.message.contains("v1.1.0") == true)

        // 同じ理由なら書き直さない
        let writes = await store.writeCount
        clock.advance(minutes: 10)
        await watch.refresh()
        #expect(await store.writeCount == writes)

        // 人がタグを手で付けたら、そのコミットで続ける
        hosting.state.withLock { $0.tags["v1.1.0"] = Self.released }
        clock.advance(minutes: 10)
        await watch.refresh()
        let resumed = try await release()
        #expect(resumed.commit?.source == .existingTag && resumed.problem == nil && resumed.notes != nil)
    }

    @Test func readsAppStoreConnectEveryThirtyMinutesAndAddsPlatforms() async throws {
        try await addRepository()
        live()
        let watch = watch()
        await watch.refresh()
        clock.advance(minutes: 10)
        await watch.refresh()
        #expect(appStore.state.withLock { $0.reads } == 1)

        live(.macOS, build: "32")
        clock.advance(minutes: 20)
        await watch.refresh()
        #expect(appStore.state.withLock { $0.reads } == 2)
        #expect(try await release().platforms.map(\.platform) == [.iOS, .macOS])
    }

    @Test func reportsWhatWaitsForHumanAndNotifiesIt() async throws {
        try await addRepository()
        live()
        let watch = watch()
        await watch.refresh()
        // コミットを決められない（Upload の実行が無い）と人が直す問題、決まればリリース文の確認が、人を待つものになる
        let problem = try #require(await watch.blockers.first)
        #expect(problem.reason == .releaseProblem(.commit))
        #expect(problem.scope == .release(Self.repo, Self.version))

        hosting.state.withLock { $0.runs = [uploadRun()] }
        clock.advance(minutes: 10)
        await watch.refresh()
        let blockers = await watch.blockers
        #expect(blockers.map(\.key) == ["release/shariverse/oshikatsu-countdown-ios/1.1.0/1"])
        #expect(blockers.map(\.reason) == [.releaseNotes])

        let notice = try #require(PushNotice.compose(blockers, epics: [], now: Self.now).first)
        #expect(notice.title == "oshikatsu-countdown-ios 1.1.0 を配信しました")
        #expect(notice.body == "リリース文を確かめて、GitHub Release を公開してください")
        #expect(notice.target == ["repo": "shariverse/oshikatsu-countdown-ios", "release": "1.1.0"])
        #expect(notice.thread == "release/shariverse/oshikatsu-countdown-ios/1.1.0")
    }

    @Test func continuesPostWorkWithoutAppStoreConnectKeys() async throws {
        try await addRepository()
        let uploadedAt = Timestamp(Self.now.addingTimeInterval(-600 * 60))
        try await put(ReleaseFile(
            repo: Self.repo,
            version: Self.version,
            platforms: [.init(platform: .iOS, build: "31", uploadedAt: uploadedAt, detectedAt: Timestamp(Self.now))],
            detectedAt: Timestamp(Self.now),
            updatedAt: Timestamp(Self.now)
        ))
        hosting.state.withLock { $0.runs = [uploadRun()] }
        await watch(stores: []).refresh()
        #expect(try await release().tag?.name == "v1.1.0")
    }
}
