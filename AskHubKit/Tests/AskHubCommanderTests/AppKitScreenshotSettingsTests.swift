@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// ずれの点検で、app-kit の撮影を使うアプリの撮影の設定を作る・確かめる（#1303）
struct AppKitScreenshotSettingsTests {
    static let repo = RepositoryFullName(rawValue: "tm-family/shinkeisuijaku-app-ios")!
    static let head = String(repeating: "c", count: 40)
    typealias Builder = StoreScreenshotSettingsBuilder

    /// base の先頭のファイル
    struct BaseFile {
        var path: String
        var sha: String
        var text: String
    }

    /// sha は、まとめて読む順（sha の順）がパスの順になるように付ける
    static let files = [
        BaseFile(path: ".github/app-kit.json", sha: String(repeating: "1", count: 40), text: AppKitRolloutTests.config),
        BaseFile(
            path: ".github/workflows/build.yml",
            sha: String(repeating: "2", count: 40),
            text: AppKitRelease.render(AppKitAdoptionTests.callerBuild, pin: AppKitRolloutTests.new)
        ),
        BaseFile(
            path: Builder.screenshotsPath, sha: String(repeating: "3", count: 40), text: StoreScreenshotSettingsBuilderTests.screenshots
        ),
        BaseFile(path: Builder.languagesPath, sha: String(repeating: "4", count: 40), text: StoreScreenshotSettingsBuilderTests.japanese),
        BaseFile(path: Builder.workflowPath, sha: String(repeating: "5", count: 40), text: "")
    ]

    /// ブランチの先頭 → tree → 中身（GraphQL でまとめて 1 回）
    static func replies(files: [BaseFile] = files) throws -> [StubTransport.Reply] {
        let tree = files.map { AppKitSetupTests.treeEntry($0.path, $0.sha) }.joined(separator: ",")
        let read = files.filter { $0.path != Builder.workflowPath }.sorted { $0.sha < $1.sha }
        var blobs: [String] = []
        for (index, file) in read.enumerated() {
            let text = try #require(String(data: try JSONEncoder().encode(file.text), encoding: .utf8))
            blobs.append(#""b\#(index)":{"text":\#(text),"isBinary":false,"isTruncated":false}"#)
        }
        return [
            .json(200, #"{"ref":"refs/heads/develop","object":{"sha":"\#(head)","type":"commit"}}"#),
            .json(200, #"{"sha":"\#(head)","truncated":false,"tree":[\#(tree)]}"#),
            .data(#"{"repository":{\#(blobs.joined(separator: ","))}}"#)
        ]
    }

    static func repository(storeScreenshots: StoreScreenshotCapture? = nil) throws -> RepositoryFile {
        var file = RepositoryFile(repo: repo, platform: .apple, addedAt: Timestamp(AppKitRolloutTests.now))
        var build = try AppKitAdoptionTests.build()
        build.baseBranch = "develop"
        build.storeScreenshots = storeScreenshots
        file.build = build
        return file
    }

    static func watch(
        _ store: InMemoryStateStore,
        transport: StubTransport,
        groups: (@Sendable () async throws -> [AppStorePlacementProfileGroup])?,
        clock: TestClock = TestClock(AppKitRolloutTests.now),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> AppKitWatch {
        AppKitWatch(
            context: CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { clock.now },
            source: FixedAppKitSource(releases: [AppKitRolloutTests.old, AppKitRolloutTests.new].map(AppKitRolloutTests.release)),
            github: { GitHubPullRequests(repository: $0, transport: transport) { _ in "github_pat_daily" } },
            admin: nil,
            log: log,
            placementGroups: groups
        )
    }

    static func read(_ store: InMemoryStateStore) async throws -> RepositoryFile {
        let data = try #require(await store.data(at: StatePath.repository(repo)))
        return try StateFileCoder.decode(RepositoryFile.self, from: data)
    }

    /// 手で入れ替え、設定の無いアプリ（shinkeisuijaku の形）に、呼んでいる版と撮影の設定を一緒に書き、配置グループを 1 回ログに出す
    @Test func writesSettingsAndVersionOfRepositoryWithoutThem() async throws {
        let store = InMemoryStateStore()
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(try Self.repository()))
        let logs = LogLines()
        let watch = Self.watch(
            store,
            transport: StubTransport(try Self.replies()),
            groups: { StoreScreenshotSettingsBuilderTests.groups },
            log: { logs.append($0) }
        )
        try await watch.check(Self.repo, releases: AppKitRolloutTests.releases())
        let file = try await Self.read(store)
        #expect(file.appKit?.ref == AppKitRolloutTests.new.ref && file.appKit?.version == AppKitRolloutTests.new.version)
        #expect(file.build?.storeScreenshots == .actions(StoreScreenshotSettingsBuilderTests.built))
        // 写すファイルのずれだけで、撮影の設定の問題は無い
        #expect(file.appKit?.drift?.problems.contains { $0.hasPrefix(Builder.problemPrefix) } == false)
        let listed = "App Store Connect のリファレンスデータの配置グループ: IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE（"
        #expect(logs.lines.contains { $0.hasPrefix(listed) })
        #expect(logs.lines.contains("\(Self.repo) の撮影の設定を作った（iPad 13 inch・iPhone 6.3 inch・iPhone 6.9 inch・iPhone Duo × ja）"))
    }

    /// リファレンスデータを読めなければ、設定は作らずに版だけを書く（次の点検で作る）
    @Test func writesOnlyVersionWhenReferenceDataIsUnavailable() async throws {
        let store = InMemoryStateStore()
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(try Self.repository()))
        let watch = Self.watch(store, transport: StubTransport(try Self.replies()), groups: { throw AppStoreConnectError.unavailable("x") })
        try await watch.check(Self.repo, releases: AppKitRolloutTests.releases())
        let file = try await Self.read(store)
        #expect(file.appKit?.ref == AppKitRolloutTests.new.ref)
        #expect(file.build?.storeScreenshots == nil)
    }

    /// リファレンスデータは 1 日覚え、それより古いものでは作らない（読み直せなければ作らずに次の点検で作る）
    @Test func doesNotBuildSettingsFromExpiredReferenceData() async throws {
        let reads = LogLines()
        let groups: @Sendable () async throws -> [AppStorePlacementProfileGroup] = {
            reads.append("read")
            guard reads.lines.count == 1 else { throw AppStoreConnectError.unavailable("x") }
            return StoreScreenshotSettingsBuilderTests.groups
        }
        let clock = TestClock(AppKitRolloutTests.now)
        let store = InMemoryStateStore()
        let watch = Self.watch(store, transport: StubTransport(try Self.replies() + Self.replies()), groups: groups, clock: clock)
        #expect(await watch.referenceGroups() == StoreScreenshotSettingsBuilderTests.groups)
        clock.advance(minutes: 60)
        #expect(await watch.referenceGroups() == StoreScreenshotSettingsBuilderTests.groups && reads.lines.count == 1)
        clock.advance(minutes: 24 * 60)
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(try Self.repository()))
        try await watch.check(Self.repo, releases: AppKitRolloutTests.releases())
        #expect(reads.lines.count == 2)
        #expect(try await Self.read(store).build?.storeScreenshots == nil)
    }

    /// 人が書いた設定は書き換えず、食い違いをずれに書く。app-kit の撮影を unmanaged にしたアプリは見ない
    @Test func keepsHandWrittenSettingsAndSkipsUnmanagedWorkflow() async throws {
        var handWritten = StoreScreenshotSettingsBuilderTests.built
        handWritten.artifacts["IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE"] = nil
        let store = InMemoryStateStore()
        let file = try Self.repository(storeScreenshots: .actions(handWritten))
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        let watch = Self.watch(store, transport: StubTransport(try Self.replies()), groups: { StoreScreenshotSettingsBuilderTests.groups })
        try await watch.check(Self.repo, releases: AppKitRolloutTests.releases())
        let kept = try await Self.read(store)
        #expect(kept.build?.storeScreenshots == .actions(handWritten))
        #expect(kept.appKit?.drift?.problems.contains(
            "撮影の設定: AppStore/screenshots.json の APP_IPHONE_61（iPhone 6.3 inch）が build.storeScreenshots.artifacts に無い"
                + "（足すなら IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE）"
        ) == true)

        var files = Self.files
        files[0].text = #"{"v":1,"project":"Kobosu.xcodeproj","scheme":"Kobosu","platforms":["iOS"],"#
            + #""unmanaged":["\#(Builder.workflowPath)"]}"#
        let unmanaged = InMemoryStateStore()
        await unmanaged.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(try Self.repository()))
        let transport = StubTransport(try Self.replies(files: files))
        let quiet = Self.watch(unmanaged, transport: transport, groups: { StoreScreenshotSettingsBuilderTests.groups })
        try await quiet.check(Self.repo, releases: AppKitRolloutTests.releases())
        let skipped = try await Self.read(unmanaged)
        #expect(skipped.appKit != nil && skipped.build?.storeScreenshots == nil)
        #expect(skipped.appKit?.drift?.problems.contains { $0.hasPrefix(Builder.problemPrefix) } == false)
    }
}
