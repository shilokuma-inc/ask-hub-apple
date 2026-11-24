@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 準備をやり直したとき（`addRepository` の再送）、開いている準備の PR を今の中身に合わせる
struct RepositorySetupRebuildTests {
    static let repo = RepositorySetupTests.repo
    static let now = RepositorySetupTests.now
    static let base = RepositorySetupTests.base
    static let commit = RepositorySetupTests.commit
    static let rebuilt = String(repeating: "a", count: 40)

    func context(_ store: any StateStore) -> CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
    }

    /// 送った要求（メソッドとパス）
    static func requests(_ transport: StubTransport) -> [String] {
        transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
    }

    /// 準備の初めの、Discussions が有効で Ideas があり、準備の PR #12（head は `commit`）が開いているところまで
    static let opening: [StubTransport.Reply] = [
        .json(200, #"{"default_branch":"develop","private":false,"has_discussions":true}"#),
        .data(#"{"repository":{"discussionCategories":{"nodes":[{"name":"Ideas"}]}}}"#),
        .json(200, "[\(RepositorySetupTests.pullRequest())]"),
        .json(200, #"{"object":{"sha":"\#(base)","type":"commit"}}"#)
    ]

    /// 作り直す tree を作り、PR の head の tree（`current`）と比べるところまで
    static func comparing(current tree: Character) -> [StubTransport.Reply] {
        [
            .json(200, #"{"sha":"\#(base)","tree":{"sha":"\#(String(repeating: "5", count: 40))"}}"#),
            .json(201, #"{"sha":"\#(String(repeating: "6", count: 40))"}"#),
            .json(200, #"{"sha":"\#(commit)","tree":{"sha":"\#(String(repeating: tree, count: 40))"}}"#)
        ]
    }

    /// ビルドの設定の前に加えて app-kit なしの準備の PR が開いている。ビルドの設定を入れてから準備をやり直すと、
    /// 作業ブランチだけを app-kit 入りの中身に作り直して PR の題と本文を書き換え、前の head への承認ではマージしない
    @Test func retryRebuildsOpenPullRequestWithAppKit() async throws {
        let legacy = WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit, changes: [Self.legacyChanges[0]])
        let store = try await AppKitSetupTests().store(build: try AppKitAdoptionTests.build(childChecks: ["Build"]), workflows: legacy)
        let oldBuild = "name: Build\non:\n  push:\n    paths-ignore: ['**/*.md']\n"
            + "jobs:\n  Build:\n    uses: ./.github/workflows/_build.yml\n"
        let reusable = "on: workflow_call\njobs:\n  build:\n    steps:\n      - name: Write secrets\n        run: x\n"
        let tree = [
            AppKitSetupTests.treeEntry(".github/workflows/build.yml", String(repeating: "2", count: 40)),
            AppKitSetupTests.treeEntry(".github/workflows/_build.yml", String(repeating: "3", count: 40)),
            AppKitSetupTests.treeEntry("KobosuUITests/A.swift", String(repeating: "4", count: 40))
        ].joined(separator: ",")
        let quoted = try #require(String(data: try JSONEncoder().encode(reusable), encoding: .utf8))
        let transport = StubTransport(Self.opening + [
            .json(200, "[\(AppKitSetupTests.entry("build.yml", "2")),\(AppKitSetupTests.entry("_build.yml", "3"))]"),
            RepositorySetupTests.blob(oldBuild),
            RepositorySetupTests.blob(reusable),
            .json(200, #"{"sha":"\#(Self.base)","truncated":false,"tree":[\#(tree)]}"#),
            .data(#"{"repository":{"b0":{"text":\#(quoted),"isBinary":false,"isTruncated":false}}}"#)
        ] + Self.comparing(current: "7") + [
            .json(201, #"{"sha":"\#(Self.rebuilt)"}"#),
            .json(200, #"{"object":{"sha":"\#(Self.commit)","type":"commit"}}"#),
            .json(200, "{}"),
            .json(200, "{}")
        ])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        let source = FixedAppKitSource(release: AppKitAdoptionTests.release)
        try await RepositorySetupStep(admin: admin, appKit: source).run(for: Self.repo, in: context(store))
        let workflows = try #require(try await AppKitSetupTests().repository(in: store)?.setup?.workflows)
        #expect(workflows.state == .open && workflows.pullRequest == 12 && workflows.head == Self.rebuilt)
        #expect(workflows.appKit?.version == AppKitSetupTests.pin.version)
        #expect(workflows.appKit?.renamedChecks == [CheckRename(from: "Build", to: "build / build")])
        // 作り直すのは作業ブランチだけ（base の develop には書かない）。親は今の base の head
        #expect(Array(Self.requests(transport).suffix(4)) == [
            "POST /repos/shilokuma-inc/askhub-sandbox/git/commits",
            "GET /repos/shilokuma-inc/askhub-sandbox/git/ref/heads/askhub/setup-workflows",
            "PATCH /repos/shilokuma-inc/askhub-sandbox/git/refs/heads/askhub/setup-workflows",
            "PATCH /repos/shilokuma-inc/askhub-sandbox/pulls/12"
        ])
        let bodies = transport.bodies
        let commit = try #require(bodies.first { $0["parents"] != nil })
        #expect(commit["parents"] == .array([.string(Self.base)]))
        #expect(bodies.contains { $0["sha"] == .string(Self.rebuilt) && $0["force"] == .bool(true) })
        let pull = try #require(bodies.last)
        #expect(pull["title"] == .string("【CI】AskHub の準備: CI・リリースのワークフローを app-kit v1.0.0 に入れ替える"))

        // 前の head（app-kit なし）を見た承認は、GitHub に送らずに断る
        let count = transport.requests.count
        let approval = try await ApproveSetupPullRequestHandler(admin: admin).handle(approveEnvelope(head: Self.commit), in: context(store))
        #expect(approval == .reject("承認したときと準備の PR が違う（今は open）。見直して承認し直す"))
        #expect(transport.requests.count == count)
        #expect(try await AppKitSetupTests().repository(in: store)?.setup?.workflows?.head == Self.rebuilt)
    }

    /// 今の base の head から作り直しても中身（tree）が同じなら、ブランチも PR も変えない
    @Test func retryKeepsOpenPullRequestWithSameContent() async throws {
        let previous = WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit, changes: Self.legacyChanges)
        let transport = StubTransport(Self.legacyReplies + Self.comparing(current: "6"))
        let github = GitHubPullRequests(repository: Self.repo, transport: transport) { _ in "t" }
        let setup = await RepositorySetupRunner(github: github, now: Timestamp(Self.now)).run(build: nil, previous: previous).setup
        #expect(setup.problems == nil)
        #expect(setup.workflows == previous)
        #expect(Self.requests(transport).last == "GET /repos/shilokuma-inc/askhub-sandbox/git/commits/\(Self.commit)")
        #expect(!Self.requests(transport).contains { $0.hasPrefix("PATCH") })
    }

    /// 中身は同じでも、記録が開いている PR と違う（前の作り直しが記録する前に止まった）なら、題と本文を今の中身にして記録し直す
    @Test func retryRewritesBodyWhenRecordIsBehind() async throws {
        let previous = WorkflowSetup(state: .open, pullRequest: 12, head: String(repeating: "d", count: 40))
        let transport = StubTransport(Self.legacyReplies + Self.comparing(current: "6") + [.json(200, "{}")])
        let github = GitHubPullRequests(repository: Self.repo, transport: transport) { _ in "t" }
        let setup = await RepositorySetupRunner(github: github, now: Timestamp(Self.now)).run(build: nil, previous: previous).setup
        #expect(setup.workflows == WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit, changes: Self.legacyChanges))
        #expect(Self.requests(transport).last == "PATCH /repos/shilokuma-inc/askhub-sandbox/pulls/12")
        #expect(!Self.requests(transport).contains { $0.contains("git/refs") || $0.hasSuffix("git/commits") })
    }

    /// app-kit の版を読めなければ、今の中身が分からないので、開いている PR を作り直さずに残す
    @Test func retryKeepsOpenPullRequestWhenAppKitIsUnread() async throws {
        let previous = WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit, changes: Self.legacyChanges)
        let store = try await AppKitSetupTests().store(build: try AppKitAdoptionTests.build(), workflows: previous)
        let transport = StubTransport(Self.opening + [.json(200, "[]")])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        try await RepositorySetupStep(admin: admin, appKit: FixedAppKitSource()).run(for: Self.repo, in: context(store))
        let setup = try #require(try await AppKitSetupTests().repository(in: store)?.setup)
        #expect(setup.workflows == previous)
        #expect(setup.problems?.first?.hasPrefix("app-kit の中身の形が違う（版 v1.0.0 が無い）") == true)
        #expect(transport.requests.count == 5)
    }

    /// 今の base では直すところが無いなら、開いている PR を残し、閉じるよう人に知らせる
    @Test func retryReportsOpenPullRequestWithNothingToChange() async throws {
        let previous = WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit, changes: Self.legacyChanges)
        let transport = StubTransport(Self.opening + [.json(200, "[]")])
        let github = GitHubPullRequests(repository: Self.repo, transport: transport) { _ in "t" }
        let setup = await RepositorySetupRunner(github: github, now: Timestamp(Self.now)).run(build: nil, previous: previous).setup
        #expect(setup.workflows == previous)
        #expect(setup.problems == [
            RepositorySetupRunner.unresolved("build"),
            "開いている準備の PR #12 は、今の base では直すところが無い。GitHub で閉じてから準備をやり直す"
        ])
        #expect(transport.requests.count == 5)
    }

    // MARK: - 部品

    /// 今の仕組みのワークフロー（待つチェックの絞り・ゴールの Discussion を閉じる）の直し
    static let legacyChanges: [WorkflowChange] = [
        .init(kind: .removePathFilters, path: ".github/workflows/build.yml"),
        .init(kind: .removeLegacy, path: ".github/workflows/close-goal-discussion.yml")
    ]

    /// 開いている準備の PR があり、base の head のワークフローが今の仕組みのまま（`legacyChanges` を直す）のところまで
    static var legacyReplies: [StubTransport.Reply] {
        let entries = "[\(AppKitSetupTests.entry("build.yml", "2")),\(AppKitSetupTests.entry("close-goal-discussion.yml", "3"))]"
        return Self.opening + [
            .json(200, entries),
            RepositorySetupTests.blob(RepositorySetupTests.build),
            RepositorySetupTests.blob(RepositorySetupTests.closeGoal)
        ]
    }

    private func approveEnvelope(head: String) -> IntentEnvelope {
        IntentEnvelope(
            kind: ApproveSetupPullRequestIntent.kind,
            repo: Self.repo,
            target: .init(type: ApproveSetupPullRequestIntent.targetType, id: "12"),
            targetVersion: head,
            payload: [:],
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }
}
