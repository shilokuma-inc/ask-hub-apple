@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// app-kit の版を見つける・広げる・ずれを点検する
struct AppKitRolloutTests {
    static let now = RepositorySetupTests.now
    static let old = AppKitAdoptionTests.pin
    static let new = AppKitFile.Pin(version: AppKitVersion(rawValue: "v1.0.1")!, ref: String(repeating: "b", count: 40))
    static let pilot = AppKitPolicy.defaultPilot
    static let other = RepositoryFullName(rawValue: "tm-family/kobosu-app-ios")!
    static let head = String(repeating: "c", count: 40)
    static let intent = IntentReference(
        keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
        nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!
    )
    static let pull = """
        {"number":5,"state":"open","merged":false,"head":{"ref":"askhub/app-kit-v1.0.1","sha":"\(head)",
         "repo":{"full_name":"tm-family/kobosu-app-ios"}},"base":{"ref":"develop","sha":"\(head)"}}
        """

    static func release(_ pin: AppKitFile.Pin) -> AppKitRelease {
        var release = AppKitAdoptionTests.release
        release.pin = pin
        release.managed[".github/workflows/build.yml"] = AppKitRelease.render(AppKitAdoptionTests.callerBuild, pin: pin)
        return release
    }

    func context(_ store: any StateStore) -> CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
    }

    static func releases() -> [AppKitFile.Release] {
        [
            .init(version: new.version, ref: new.ref, changes: "- 直し", foundAt: Timestamp(now)),
            .init(version: old.version, ref: old.ref, foundAt: Timestamp(now))
        ]
    }

    static func target(_ repo: RepositoryFullName, _ state: AppKitFile.Target.State, pullRequest: Int? = nil) -> AppKitFile.Target {
        let kind: AppKitFile.Target.Kind = AppKitPolicy.templates.contains(repo) ? .template : .repository
        let problem = [.failed, .skipped].contains(state) ? "x" : nil
        return .init(
            repo: repo,
            kind: kind,
            state: state,
            pullRequest: pullRequest,
            head: pullRequest.map { _ in head },
            problem: problem,
            updatedAt: Timestamp(now)
        )
    }

    func driver(_ store: InMemoryStateStore, transport: StubTransport = StubTransport([])) -> AppKitRolloutDriver {
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        let source = FixedAppKitSource(release: Self.release(Self.new))
        return AppKitRolloutDriver(context: context(store), admin: admin, source: source, log: { _ in })
    }

    func store(rollout: AppKitFile.Rollout? = nil, repositories: [(RepositoryFullName, RepositoryFile.AppKit?)] = []) async throws
        -> InMemoryStateStore {
        let store = InMemoryStateStore()
        for (repo, appKit) in repositories {
            var file = RepositoryFile(repo: repo, platform: .apple, build: try AppKitAdoptionTests.build(), addedAt: Timestamp(Self.now))
            file.appKit = appKit
            await store.put(StatePath.repository(repo), data: try StateFileCoder.encode(file))
        }
        let file = AppKitFile(releases: Self.releases(), adoption: Self.old, rollout: rollout, templates: AppKitWatch.templates([]))
        await store.put(StatePath.appKit, data: try StateFileCoder.encode(file))
        return store
    }

    func appKit(in store: InMemoryStateStore) async throws -> AppKitFile {
        try StateFileCoder.decode(AppKitFile.self, from: try #require(await store.data(at: StatePath.appKit)))
    }

    func repository(_ repo: RepositoryFullName, in store: InMemoryStateStore) async throws -> RepositoryFile {
        try StateFileCoder.decode(RepositoryFile.self, from: try #require(await store.data(at: StatePath.repository(repo))))
    }

    static func running(_ targets: [AppKitFile.Target] = []) -> AppKitFile.Rollout {
        AppKitFile.Rollout(
            version: new.version,
            ref: new.ref,
            origin: intent,
            pilot: pilot,
            targets: targets,
            startedAt: Timestamp(now),
            updatedAt: Timestamp(now)
        )
    }

    static func installed(_ pin: AppKitFile.Pin) -> RepositoryFile.AppKit {
        RepositoryFile.AppKit(ref: pin.ref, version: pin.version, installedAt: Timestamp(now))
    }

    // MARK: - 版を見つける

    @Test func readsChangelogSectionOfTheVersion() throws {
        let text = """
            # CHANGELOG

            ## Unreleased

            ## v1.0.10（2026-12-01）

            - 別の版

            ## v1.0.1（2026-11-25）

            - Upload の直し
            - 撮影の直し

            ## v1.0.0（2026-11-22）

            最初の版。
            """
        #expect(AppKitChangelog.section(of: Self.new.version, in: text) == "- Upload の直し\n- 撮影の直し")
        #expect(AppKitChangelog.section(of: Self.old.version, in: text) == "最初の版。")
        #expect(AppKitChangelog.section(of: AppKitVersion(rawValue: "v2.0.0")!, in: text) == nil)
    }

    /// 注釈つきのタグは ^{} の行のコミットを使い、版の形でないタグは読まない
    @Test func gitSourceReadsTags() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppKitTags-\(UUID().uuidString)/app-kit.git")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: directory.appendingPathComponent("HEAD"))
        let tag = String(repeating: "9", count: 40)
        let listing = "\(tag)\trefs/tags/v1.0.0\n\(Self.old.ref)\trefs/tags/v1.0.0^{}\n"
            + "\(Self.new.ref)\trefs/tags/v1.0.1\n\(tag)\trefs/tags/latest\n"
        let git = AppKitGit(["ls-remote": AppKitAdoptionTests.output(listing)])
        let tags = try await GitAppKitSource(setup: .init(directory: directory), runner: git).tags()
        #expect(tags == [Self.new, Self.old])
    }

    @Test func writesFoundReleasesAdoptionAndTemplates() async throws {
        let store = InMemoryStateStore()
        let source = FixedAppKitSource(tags: [Self.new, Self.old], changelog: [Self.new.version: "- 直し"])
        let watch = AppKitWatch(
            context: context(store), source: source, github: { _ in fatalError("読まない") }, admin: nil, log: { _ in }
        )
        await watch.refreshReleases()
        let file = try await appKit(in: store)
        #expect(file.releases.map(\.version) == [Self.new.version, Self.old.version])
        #expect(file.latest?.changes == "- 直し")
        #expect(file.release(Self.old.version)?.changes == nil)
        // 最初に見つけたときは、一番新しい版を入れ替えに使う
        #expect(file.adoption == Self.new)
        #expect(file.templates.map(\.repo) == AppKitPolicy.templates)
        #expect(file.checkedAt == Timestamp(Self.now))
    }

    // MARK: - 広げる・やめる

    private func envelope(_ kind: String, pin: AppKitFile.Pin = Self.new) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            target: .init(type: AppKitReleaseTarget.targetType, id: pin.version.rawValue),
            targetVersion: pin.ref,
            payload: [:],
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    private var admin: AdminGitHub { AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: StubTransport([])) }

    @Test func rolloutStartsAndRefusesChangedOrOtherVersion() async throws {
        let store = try await store()
        let handler = RolloutAppKitHandler(admin: admin)
        #expect(try await handler.handle(envelope(RolloutAppKitIntent.kind), in: context(store)) == .accept)
        let rollout = try #require(try await appKit(in: store).rollout)
        #expect(rollout.state == .running && rollout.version == Self.new.version && rollout.pilot == Self.pilot && rollout.targets.isEmpty)
        // 見たときと違うコミット・ほかの版を広げている途中は断る
        let moved = AppKitFile.Pin(version: Self.new.version, ref: String(repeating: "d", count: 40))
        #expect(try await handler.handle(envelope(RolloutAppKitIntent.kind, pin: moved), in: context(store))
            == .reject("app-kit v1.0.1 のコミットが、見たときと違う。見直して押し直す"))
        #expect(try await handler.handle(envelope(RolloutAppKitIntent.kind, pin: Self.old), in: context(store))
            == .reject("app-kit v1.0.1 を広げている途中。やめてから v1.0.0 を広げる"))
        #expect(try await RolloutAppKitHandler(admin: nil).handle(envelope(RolloutAppKitIntent.kind), in: context(store))
            == .reject("この司令塔は管理用のトークンを使えない（常時オンの Mac の askhub-commander で動かす）"))
    }

    /// 止めた版をもう一度広げると、開いたままの PR は追い直し、ほかの相手は確かめ直す
    @Test func retryKeepsOpenPullRequests() throws {
        let open = Self.target(Self.other, .failed, pullRequest: 5)
        let kept = RolloutAppKitHandler.kept([open, Self.target(Self.pilot, .done), Self.target(AppKitPolicy.templates[1], .skipped)])
        #expect(kept.map(\.repo) == [Self.other])
        #expect(kept.first?.state == .open && kept.first?.problem == nil && kept.first?.pullRequest == 5)
    }

    @Test func stopClosesOpenPullRequests() async throws {
        let store = try await store(rollout: Self.running([Self.target(Self.other, .open, pullRequest: 5)]))
        let transport = StubTransport([.json(200, Self.pull), .json(200, Self.pull)])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        let stop = try await StopAppKitRolloutHandler(admin: admin).handle(envelope(StopAppKitRolloutIntent.kind), in: context(store))
        #expect(stop == .accept)
        let rollout = try #require(try await appKit(in: store).rollout)
        #expect(rollout.state == .stopped)
        #expect(rollout.targets.first?.state == .stopped)
        #expect(transport.requests.last?.httpMethod == "PATCH")
        #expect(transport.bodies.last?["state"] == .string("closed"))
    }

    // MARK: - 進め方

    /// 入れ替えていない試しの 1 本には出せないので、広げるのを止める
    @Test func stopsWhenPilotHasNoAppKit() async throws {
        let store = try await store(rollout: Self.running(), repositories: [(Self.pilot, nil), (Self.other, Self.installed(Self.old))])
        try await driver(store).advance()
        let rollout = try #require(try await appKit(in: store).rollout)
        #expect(rollout.state == .failed)
        #expect(rollout.targets.map(\.state) == [.failed])
        let prefix = "試しの 1 本 tm-family/shinkeisuijaku-app-ios で止めた（試しの 1 本に出せない（まだ app-kit に入れ替えていない"
        #expect(rollout.problem?.hasPrefix(prefix) == true)
    }

    /// もう版が入っている相手は PR を出さずに済ませ、入れていない相手は理由を付けて飛ばし、出す相手が無くなったら広げ終わる
    @Test func finishesWhenEveryoneIsDoneOrSkipped() async throws {
        let store = try await store(rollout: Self.running(), repositories: [(Self.pilot, Self.installed(Self.new)), (Self.other, nil)])
        try await driver(store).advance()
        let file = try await appKit(in: store)
        let rollout = try #require(file.rollout)
        #expect(rollout.targets.map(\.repo) == [Self.pilot, Self.other])
        #expect(rollout.targets.map(\.state) == [.done, .skipped])
        #expect(rollout.state == .finished)
        #expect(file.adoption == Self.new)
    }

    /// 写すファイルのほかが変わった PR はマージしない
    @Test func refusesPullRequestChangingOtherFiles() async throws {
        let targets = [Self.target(Self.pilot, .done), Self.target(Self.other, .open, pullRequest: 5)]
        let repositories = [(Self.pilot, Self.installed(Self.new)), (Self.other, Self.installed(Self.old))]
        let store = try await store(rollout: Self.running(targets), repositories: repositories)
        let transport = StubTransport([
            .json(200, Self.pull),
            .json(200, #"[{"filename":".github/workflows/build.yml"},{"filename":"App/Secret.swift"}]"#)
        ])
        try await driver(store, transport: transport).advance()
        let target = try #require(try await appKit(in: store).rollout?.target(Self.other))
        #expect(target.state == .failed)
        #expect(target.problem == "PR #5 で写すファイルのほか（App/Secret.swift）が変わっているので、マージしない")
        #expect(!transport.requests.contains { $0.httpMethod == "PUT" })
    }

    /// 待つチェックが通ったら merge commit でマージし、入れた版を書く
    @Test func mergesWhenChecksPassAndRecordsInstalledVersion() async throws {
        let targets = [Self.target(Self.pilot, .done), Self.target(Self.other, .open, pullRequest: 5)]
        let repositories = [(Self.pilot, Self.installed(Self.new)), (Self.other, Self.installed(Self.old))]
        let store = try await store(rollout: Self.running(targets), repositories: repositories)
        let run = """
            {"id":1,"name":"build / build","status":"completed","conclusion":"success","started_at":"2026-11-25T10:00:00Z",
             "details_url":"https://example.com","html_url":"https://example.com","app":{"slug":"github-actions"}}
            """
        let merge = String(repeating: "e", count: 40)
        let transport = StubTransport([
            .json(200, Self.pull),
            .json(200, #"[{"filename":".github/workflows/build.yml"}]"#),
            .json(200, #"{"total_count":1,"check_runs":[\#(run)]}"#),
            .json(200, #"{"state":"success","total_count":0,"statuses":[]}"#),
            .json(200, #"{"sha":"\#(merge)","merged":true,"message":"merged"}"#)
        ])
        try await driver(store, transport: transport).advance()
        let target = try #require(try await appKit(in: store).rollout?.target(Self.other))
        #expect(target.state == .done)
        #expect(target.mergeCommit == merge)
        #expect(try await repository(Self.other, in: store).appKit == Self.installed(Self.new))
        #expect(transport.bodies.last?["merge_method"] == .string("merge"))
        #expect(transport.bodies.last?["sha"] == .string(Self.head))
    }

    @Test func uploadVerdictTreatsSkippedAsPassed() {
        let run = { (name: String, status: String, conclusion: String?) in
            CheckRunStatus(name: name, app: "github-actions", status: status, conclusion: conclusion)
        }
        #expect(AppKitRolloutDriver.uploadVerdict([]) == .pending)
        #expect(AppKitRolloutDriver.uploadVerdict([run("upload", "completed", "skipped")]) == .passed)
        #expect(AppKitRolloutDriver.uploadVerdict([run("upload / archive", "in_progress", nil)]) == .pending)
        #expect(AppKitRolloutDriver.uploadVerdict([run("upload / archive", "completed", "failure")]) == .failed)
    }

    // MARK: - ずれ

    static let config = #"{"v":1,"project":"Kobosu.xcodeproj","scheme":"Kobosu","platforms":["iOS"]}"#

    static func observed(_ release: AppKitRelease, config: String? = config) -> AppKitObserved {
        var files = Dictionary(uniqueKeysWithValues: release.managed.map { ($0.key, GitBlob.sha(of: $0.value)) })
        files[AppKitPolicy.configPath] = String(repeating: "f", count: 40)
        return AppKitObserved(files: files, config: config, callerRef: release.pin.ref, callerKitRef: release.pin.ref)
    }

    @Test func findsDriftOfManagedFilesAndConfig() throws {
        let release = Self.release(Self.old)
        let build = try AppKitAdoptionTests.build()
        #expect(AppKitDrift.problems(release: release, observed: Self.observed(release), build: build).isEmpty)
        let config = #"{"v":1,"project":"Old.xcodeproj","scheme":"Kobosu","platforms":["iOS"],"unmanaged":[".coderabbit.yaml"]}"#
        var observed = Self.observed(release, config: config)
        observed.files[".github/workflows/build.yml"] = String(repeating: "0", count: 40)
        observed.files[".coderabbit.yaml"] = String(repeating: "0", count: 40)
        observed.files[".swiftlint.yml"] = nil
        #expect(AppKitDrift.problems(release: release, observed: observed, build: build) == [
            ".github/workflows/build.yml が app-kit v1.0.0 の中身と違う",
            ".swiftlint.yml が無い（app-kit v1.0.0 の写すファイル）",
            ".github/app-kit.json の project（Old.xcodeproj）が、ビルドの設定（Kobosu.xcodeproj）と違う"
        ])
        observed.config = nil
        #expect(AppKitDrift.problems(release: release, observed: observed, build: build) == [".github/app-kit.json が無い"])
    }

    /// 呼んでいるコミットが見つけた別の版で、写すファイルがその版と同じなら、その版が入ったとみなす（GitHub で人がマージしたとき）
    @Test func recognizesVersionMergedByHand() async throws {
        let source = FixedAppKitSource(releases: [Self.release(Self.old), Self.release(Self.new)])
        let observed = Self.observed(Self.release(Self.new))
        let next = try await AppKitWatch.installation(
            installed: Self.installed(Self.old),
            observed: observed,
            build: try AppKitAdoptionTests.build(),
            catalog: AppKitCatalog(releases: Self.releases(), source: source),
            now: Timestamp(Self.now)
        )
        #expect(next == Self.installed(Self.new))
        // 入っている版のまま写すファイルが違えば、ずれを書く
        var drifted = Self.observed(Self.release(Self.old))
        drifted.files[".swiftlint.yml"] = String(repeating: "0", count: 40)
        let drift = try await AppKitWatch.installation(
            installed: Self.installed(Self.old),
            observed: drifted,
            build: nil,
            catalog: AppKitCatalog(releases: Self.releases(), source: source),
            now: Timestamp(Self.now)
        )
        #expect(drift?.ref == Self.old.ref)
        #expect(drift?.drift?.problems == [".swiftlint.yml が app-kit v1.0.0 の中身と違う"])
    }
}
