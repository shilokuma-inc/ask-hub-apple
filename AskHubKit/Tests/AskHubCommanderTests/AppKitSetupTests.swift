@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 対象に加えるときの準備の PR に app-kit への入れ替えを足し、承認でチェックの名前を替えてからマージする
struct AppKitSetupTests {
    static let repo = RepositorySetupTests.repo
    static let now = RepositorySetupTests.now
    static let base = RepositorySetupTests.base
    static let commit = RepositorySetupTests.commit
    static let pin = AppKitAdoptionTests.pin

    func context(_ store: any StateStore) -> CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
    }

    func store(build: RepositoryFile.Build?, protection: RepositoryFile.Protection = .init(), workflows: WorkflowSetup? = nil) async throws
        -> InMemoryStateStore {
        let store = InMemoryStateStore()
        var file = RepositoryFile(repo: Self.repo, platform: .apple, protection: protection, build: build, addedAt: Timestamp(Self.now))
        if let workflows { file.setup = RepositorySetup(updatedAt: Timestamp(Self.now), discussions: .ready, workflows: workflows) }
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        let release = AppKitFile.Release(version: Self.pin.version, ref: Self.pin.ref, foundAt: Timestamp(Self.now))
        let appKit = AppKitFile(releases: [release], adoption: Self.pin)
        await store.put(StatePath.appKit, data: try StateFileCoder.encode(appKit))
        return store
    }

    func repository(in store: InMemoryStateStore) async throws -> RepositoryFile? {
        try await store.data(at: StatePath.repository(Self.repo)).map { try StateFileCoder.decode(RepositoryFile.self, from: $0) }
    }

    static func entry(_ name: String, _ sha: Character) -> String {
        #"{"name":"\#(name)","path":".github/workflows/\#(name)","sha":"\#(String(repeating: sha, count: 40))","type":"file"}"#
    }

    static func treeEntry(_ path: String, _ sha: String) -> String {
        #"{"path":"\#(path)","mode":"100644","type":"blob","sha":"\#(sha)"}"#
    }

    /// 直しのコミットの tree に書いたパス
    static func treePaths(_ transport: StubTransport) throws -> [String] {
        let body = try #require(transport.bodies.first { $0["base_tree"] != nil })
        guard case let .array(entries) = body["tree"] else { return [] }
        return entries.compactMap { entry -> String? in
            if case let .object(object) = entry, case let .string(path) = object["path"] { return path }
            return nil
        }
    }

    /// 準備の初めの、Discussions が有効で Ideas があり、開いた準備の PR が無いところまで
    static let opening: [StubTransport.Reply] = [
        .json(200, #"{"default_branch":"develop","private":false,"has_discussions":true}"#),
        .data(#"{"repository":{"discussionCategories":{"nodes":[{"name":"Ideas"}]}}}"#),
        .json(200, "[]"),
        .json(200, #"{"object":{"sha":"\#(base)","type":"commit"}}"#)
    ]

    @Test func setupOpensAdoptionPullRequestWithRenamedChecks() async throws {
        let build = try AppKitAdoptionTests.build(childChecks: ["Build"])
        let store = try await store(build: build)
        let oldBuild = "name: Build\non:\n  push:\n    paths-ignore: ['**/*.md']\n"
            + "jobs:\n  Build:\n    uses: ./.github/workflows/_build.yml\n"
        let reusable = "on: workflow_call\njobs:\n  build:\n    steps:\n      - name: Write secrets\n        run: x\n"
        let tree = [
            Self.treeEntry(".github/workflows/build.yml", String(repeating: "2", count: 40)),
            Self.treeEntry(".github/workflows/_build.yml", String(repeating: "3", count: 40)),
            Self.treeEntry("KobosuUITests/A.swift", String(repeating: "4", count: 40))
        ].joined(separator: ",")
        let quoted = try #require(String(data: try JSONEncoder().encode(reusable), encoding: .utf8))
        let transport = StubTransport(Self.opening + [
            .json(200, "[\(Self.entry("build.yml", "2")),\(Self.entry("_build.yml", "3"))]"),
            RepositorySetupTests.blob(oldBuild),
            RepositorySetupTests.blob(reusable),
            .json(200, #"{"sha":"\#(Self.base)","truncated":false,"tree":[\#(tree)]}"#),
            .data(#"{"repository":{"b0":{"text":\#(quoted),"isBinary":false,"isTruncated":false}}}"#),
            .json(200, #"{"sha":"\#(Self.base)","tree":{"sha":"\#(String(repeating: "5", count: 40))"}}"#),
            .json(201, #"{"sha":"\#(String(repeating: "6", count: 40))"}"#),
            .json(201, #"{"sha":"\#(Self.commit)"}"#),
            .json(404, #"{"message":"Not Found"}"#),
            .json(201, "{}"),
            .json(200, "[]"),
            .json(201, RepositorySetupTests.pullRequest())
        ])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        let source = FixedAppKitSource(release: AppKitAdoptionTests.release)
        try await RepositorySetupStep(admin: admin, appKit: source).run(for: Self.repo, in: context(store))
        let setup = try #require(try await repository(in: store)?.setup)
        #expect(setup.problems == nil)
        let workflows = try #require(setup.workflows)
        #expect(workflows.state == .open && workflows.pullRequest == 12)
        #expect(workflows.appKit == AppKitAdoption(
            version: Self.pin.version, ref: Self.pin.ref, renamedChecks: [CheckRename(from: "Build", to: "build / build")]
        ))
        #expect(workflows.changes.map(\.kind) == [.adoptAppKit, .adoptAppKit, .adoptAppKit, .adoptAppKit, .removeReplaced])
        let removed = WorkflowChange(kind: .removeReplaced, path: ".github/workflows/_build.yml", lines: 6, steps: ["Write secrets"])
        #expect(workflows.changes.last == removed)
        // 入れ替える build.yml の paths-ignore は、今の仕組みの直しで重ねて直さない（写すファイルの中身にする）
        #expect(try Self.treePaths(transport) == [
            ".coderabbit.yaml", ".github/app-kit.json", ".github/workflows/_build.yml", ".github/workflows/build.yml", ".swiftlint.yml"
        ])
        let pull = try #require(transport.bodies.last)
        #expect(pull["title"] == .string("【CI】AskHub の準備: CI・リリースのワークフローを app-kit v1.0.0 に入れ替える"))
        guard case let .string(body) = pull["body"] else { Issue.record("本文が無い"); return }
        #expect(body.contains("- `Build` → `build / build`"))
        #expect(body.contains("- `.github/workflows/_build.yml`（6 行）。app-kit に無い手順: Write secrets"))
    }

    /// もう app-kit を呼んでいる（テンプレートから作った・手で入れ替えた）なら、PR を出さずに呼んでいる版を書く
    @Test func setupRecordsAppKitAlreadyCalled() async throws {
        let store = try await store(build: try AppKitAdoptionTests.build())
        let caller = AppKitRelease.render(AppKitAdoptionTests.callerBuild, pin: Self.pin)
        let transport = StubTransport(Self.opening + [
            .json(200, "[\(Self.entry("build.yml", "2"))]"),
            RepositorySetupTests.blob(caller)
        ])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        try await RepositorySetupStep(admin: admin, appKit: FixedAppKitSource()).run(for: Self.repo, in: context(store))
        let file = try #require(try await repository(in: store))
        #expect(file.setup?.workflows == WorkflowSetup(state: .notNeeded))
        #expect(file.appKit == RepositoryFile.AppKit(ref: Self.pin.ref, version: Self.pin.version))
        #expect(transport.requests.count == 6)
    }

    /// 版を読めなければ、入れ替えは足さずに理由を書き、今の仕組みの直しだけを確かめる
    @Test func setupWithoutReleaseKeepsLegacyChecks() async throws {
        let store = try await store(build: try AppKitAdoptionTests.build())
        let transport = StubTransport(Self.opening + [.json(200, "[]")])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        try await RepositorySetupStep(admin: admin, appKit: FixedAppKitSource()).run(for: Self.repo, in: context(store))
        let setup = try #require(try await repository(in: store)?.setup)
        #expect(setup.workflows == WorkflowSetup(state: .notNeeded))
        #expect(setup.problems?.first?.hasPrefix("app-kit の中身の形が違う（版 v1.0.0 が無い）") == true)
    }

    @Test func approvalRenamesChecksThenMergesAndRecordsAppKit() async throws {
        let renames = [CheckRename(from: "Build", to: "build / build")]
        let adoption = AppKitAdoption(version: Self.pin.version, ref: Self.pin.ref, renamedChecks: renames)
        let workflows = WorkflowSetup(
            state: .open,
            pullRequest: 12,
            head: Self.commit,
            changes: [.init(kind: .adoptAppKit, path: AppKitPolicy.configPath)],
            appKit: adoption
        )
        let protection = RepositoryFile.Protection(appliedAt: Timestamp(Self.now), requiredChecks: ["Build"], rulesetId: 7)
        let build = try AppKitAdoptionTests.build(childChecks: ["Build"])
        let store = try await store(build: build, protection: protection, workflows: workflows)
        let transport = StubTransport([
            .json(200, ProtectionTests.ruleset(id: 7, name: "askhub-protect", includes: ["refs/heads/develop"], checks: ["build / build"])),
            .json(200, RepositorySetupTests.pullRequest()),
            .json(200, #"{"sha":"\#(String(repeating: "9", count: 40))","merged":true,"message":"merged"}"#)
        ])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        let envelope = IntentEnvelope(
            kind: ApproveSetupPullRequestIntent.kind,
            repo: Self.repo,
            target: .init(type: ApproveSetupPullRequestIntent.targetType, id: "12"),
            targetVersion: Self.commit,
            payload: [:],
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
        #expect(try await ApproveSetupPullRequestHandler(admin: admin).handle(envelope, in: context(store)) == .accept)
        let requests = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(requests == [
            "PUT /repos/shilokuma-inc/askhub-sandbox/rulesets/7",
            "GET /repos/shilokuma-inc/askhub-sandbox/pulls/12",
            "PUT /repos/shilokuma-inc/askhub-sandbox/pulls/12/merge"
        ])
        let file = try #require(try await repository(in: store))
        #expect(file.build?.childChecks == ["build / build"])
        #expect(file.build?.finalChecks == ["build / build"])
        #expect(file.protection.requiredChecks == ["build / build"])
        #expect(file.setup?.workflows?.state == .merged)
        #expect(file.appKit == RepositoryFile.AppKit(ref: Self.pin.ref, version: Self.pin.version, installedAt: Timestamp(Self.now)))
    }
}
