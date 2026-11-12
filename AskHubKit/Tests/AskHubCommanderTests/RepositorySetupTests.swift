@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 対象に加えるときの GitHub 側の準備（Discussions・ワークフローの直しの PR と、その承認）
struct RepositorySetupTests {
    static let repo = ProtectionTests.repo
    static let now = ProtectionTests.now
    static let base = String(repeating: "1", count: 40)
    static let commit = String(repeating: "c", count: 40)

    static let build = """
        name: Build

        on:
          push:
            # ドキュメントだけの変更では、macOS ランナーの枠を使わないよう Build を実行しない
            paths-ignore:
              - '**/*.md'
              - 'docs/**'
            branches:
              - '**'
          pull_request:
            paths: ['App/**']
            types: [opened, synchronize]
          workflow_dispatch:

        jobs:
          build:
            uses: ./.github/workflows/_build.yml
        """

    static let closeGoal = """
        name: Close goal discussion
        on:
          pull_request:
            types: [closed]
        jobs:
          close:
            uses: shilokuma-inc/ralph-kit/.github/workflows/close-goal.yml@main
        """

    static let upload = """
        name: Upload
        on:
          push:
            paths-ignore: ['**/*.md']
            branches: [develop]
        jobs:
          upload:
            runs-on: macos-26
        """

    // MARK: - ワークフローの直し

    @Test func removesPathFiltersOnlyFromWaitedWorkflowsAndLegacyFiles() throws {
        let files = [
            WorkflowFile(path: ".github/workflows/build.yml", text: Self.build),
            WorkflowFile(path: ".github/workflows/close-goal-discussion.yml", text: Self.closeGoal),
            WorkflowFile(path: ".github/workflows/upload.yml", text: Self.upload)
        ]
        let plan = WorkflowSetupEditor.plan(files, waitedJobs: ["build"])
        #expect(plan.summary == [
            .init(kind: .removePathFilters, path: ".github/workflows/build.yml"),
            .init(kind: .removeLegacy, path: ".github/workflows/close-goal-discussion.yml")
        ])
        // 待たないチェック（Upload）は絞ったままにする
        #expect(plan.changes[".github/workflows/upload.yml"] == nil)
        #expect(plan.changes[".github/workflows/close-goal-discussion.yml"] == .some(nil))
        let change: String?? = plan.changes[".github/workflows/build.yml"]
        let edited = try #require(change.flatMap { $0 })
        #expect(edited == """
            name: Build

            on:
              push:
                branches:
                  - '**'
              pull_request:
                types: [opened, synchronize]
              workflow_dispatch:

            jobs:
              build:
                uses: ./.github/workflows/_build.yml
            """)
        // 直したものをもう一度見ても、直すところは無い
        #expect(WorkflowSetupEditor.removingPathFilters(edited) == nil)
    }

    @Test func readsJobsAndWaitedChecks() throws {
        #expect(WorkflowSetupEditor.jobIDs(in: Self.build) == ["build"])
        #expect(WorkflowSetupEditor.jobIDs(in: Self.upload) == ["upload"])
        #expect(WorkflowSetupEditor.waitedJobs(of: nil) == ["build"])
        let build = try RepositoryHandlersTests.build(childChecks: ["build / build", "lint"])
        #expect(WorkflowSetupEditor.waitedJobs(of: build) == ["build", "lint"])
        // ralph-kit を呼ぶものは、名前が違っても今の仕組みのワークフローとして外す
        #expect(WorkflowSetupEditor.isLegacy(.init(path: ".github/workflows/goal.yml", text: Self.closeGoal)))
        #expect(!WorkflowSetupEditor.isLegacy(.init(path: ".github/workflows/build.yml", text: Self.build)))
        // on の下にイベントの無い形・絞っていない形は、直さない
        #expect(WorkflowSetupEditor.removingPathFilters("on: push\njobs:\n  build:\n    runs-on: x") == nil)
        #expect(WorkflowSetupEditor.removingPathFilters("on:\n  schedule:\n    - cron: '0 0 * * *'\n") == nil)
    }

    // MARK: - 対象に加える

    private func context(_ store: any StateStore) -> CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { Self.now }
    }

    private func addEnvelope() -> IntentEnvelope {
        IntentEnvelope(
            kind: AddRepositoryIntent.kind,
            repo: Self.repo,
            payload: ["platform": .string("apple")],
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    private func repository(in store: InMemoryStateStore) async throws -> RepositoryFile? {
        try await store.data(at: StatePath.repository(Self.repo)).map { try StateFileCoder.decode(RepositoryFile.self, from: $0) }
    }

    private static func blob(_ text: String) -> StubTransport.Reply {
        .json(200, #"{"content":"\#(Data(text.utf8).base64EncodedString())","encoding":"base64"}"#)
    }

    static func pullRequest(number: Int = 12, head: String = commit, state: String = "open", merged: Bool = false) -> String {
        """
        {"number":\(number),"state":"\(state)","merged":\(merged),"head":{"ref":"askhub/setup-workflows","sha":"\(head)",
         "repo":{"full_name":"shilokuma-inc/askhub-sandbox"}},"base":{"ref":"develop","sha":"\(base)"}}
        """
    }

    @Test func addingRepositoryEnablesDiscussionsAndOpensWorkflowPullRequest() async throws {
        let store = InMemoryStateStore()
        let entry = { (name: String, sha: Character) in
            #"{"name":"\#(name)","path":".github/workflows/\#(name)","sha":"\#(String(repeating: sha, count: 40))","type":"file"}"#
        }
        let entries = "[\(entry("build.yml", "2")),\(entry("close-goal-discussion.yml", "3")),\(entry("README.md", "4"))]"
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false,"has_discussions":false}"#),
            .json(200, "{}"),
            .data(#"{"repository":{"discussionCategories":{"nodes":[{"name":"General"},{"name":"Q&A"}]}}}"#),
            .json(200, "[]"),
            .json(200, entries),
            Self.blob(Self.build),
            Self.blob(Self.closeGoal),
            .json(200, #"{"object":{"sha":"\#(Self.base)","type":"commit"}}"#),
            .json(200, #"{"sha":"\#(Self.base)","tree":{"sha":"\#(String(repeating: "5", count: 40))"}}"#),
            .json(201, #"{"sha":"\#(String(repeating: "6", count: 40))"}"#),
            .json(201, #"{"sha":"\#(Self.commit)"}"#),
            .json(404, #"{"message":"Not Found"}"#),
            .json(201, "{}"),
            .json(200, "[]"),
            .json(201, Self.pullRequest())
        ])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        #expect(try await AddRepositoryHandler(admin: admin).handle(addEnvelope(), in: context(store)) == .accept)
        let setup = try #require(try await repository(in: store)?.setup)
        #expect(setup.discussions == .missingCategory)
        #expect(setup.problems == nil)
        #expect(setup.workflows == WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit, changes: [
            .init(kind: .removePathFilters, path: ".github/workflows/build.yml"),
            .init(kind: .removeLegacy, path: ".github/workflows/close-goal-discussion.yml")
        ]))
        let requests = transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        #expect(requests.contains("PATCH /repos/shilokuma-inc/askhub-sandbox"))
        #expect(requests.contains("POST /repos/shilokuma-inc/askhub-sandbox/git/refs"))
        #expect(requests.last == "POST /repos/shilokuma-inc/askhub-sandbox/pulls")
        #expect(Set(transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") }) == ["Bearer \(ProtectionTests.adminToken)"])
        // 外すファイルは sha を null にした tree で消し、直したファイルは中身を書く
        let tree = try #require(transport.bodies.first { $0["base_tree"] != nil })
        let edited = try #require(WorkflowSetupEditor.removingPathFilters(Self.build))
        let blob: [String: JSONValue] = ["mode": .string("100644"), "type": .string("blob")]
        #expect(tree["tree"] == .array([
            .object(blob.merging(["path": .string(".github/workflows/build.yml"), "content": .string(edited)]) { $1 }),
            .object(blob.merging(["path": .string(".github/workflows/close-goal-discussion.yml"), "sha": .null]) { $1 })
        ]))
    }

    /// 管理用のトークンが無い持ち主は、加えるのは受け付け、準備だけを止めて理由を書く。GitHub には送らない
    @Test func addingRepositoryWithoutAdminTokenRecordsWhyPreparationStopped() async throws {
        let store = InMemoryStateStore()
        let transport = StubTransport([])
        let admin = AdminGitHub(tokens: AdminTokens { _ in nil }, transport: transport)
        #expect(try await AddRepositoryHandler(admin: admin).handle(addEnvelope(), in: context(store)) == .accept)
        let file = try #require(try await repository(in: store))
        #expect(file.setup?.problems == [AdminTokenProblem.missing(owner: "shilokuma-inc").description])
        #expect(file.setup?.workflows == nil)
        #expect(transport.requests.isEmpty)
        // 管理用のトークンを持たない処理（ワーカー・前の版）は、準備を流さない
        let plain = InMemoryStateStore()
        #expect(try await AddRepositoryHandler().handle(addEnvelope(), in: context(plain)) == .accept)
        #expect(try await repository(in: plain)?.setup == nil)
    }

    /// 前に出した PR が開いていれば、出し直さない
    @Test func keepsOpenWorkflowPullRequest() async throws {
        let transport = StubTransport([
            .json(200, #"{"default_branch":"develop","private":false,"has_discussions":true}"#),
            .data(#"{"repository":{"discussionCategories":{"nodes":[{"name":"Ideas"}]}}}"#),
            .json(200, "[\(Self.pullRequest())]")
        ])
        let github = GitHubPullRequests(repository: Self.repo, transport: transport) { _ in "t" }
        let previous = WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit, changes: [.init(kind: .removeLegacy, path: "a.yml")])
        let setup = await RepositorySetupRunner(github: github, now: Timestamp(Self.now)).run(build: nil, previous: previous)
        #expect(setup.discussions == .ready)
        #expect(setup.workflows == previous)
        #expect(transport.requests.count == 3)
    }

    // MARK: - 承認

    private func approveEnvelope(number: Int = 12, head: String = commit) -> IntentEnvelope {
        IntentEnvelope(
            kind: ApproveSetupPullRequestIntent.kind,
            repo: Self.repo,
            target: .init(type: ApproveSetupPullRequestIntent.targetType, id: String(number)),
            targetVersion: head,
            payload: [:],
            issuedAt: Timestamp(Self.now),
            nonce: ULID.generate(at: Self.now),
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    private func registered(_ workflows: WorkflowSetup) async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        var file = RepositoryFile(repo: Self.repo, platform: .apple, addedAt: Timestamp(Self.now))
        file.setup = RepositorySetup(updatedAt: Timestamp(Self.now), discussions: .ready, workflows: workflows)
        await store.put(StatePath.repository(Self.repo), data: try StateFileCoder.encode(file))
        return store
    }

    @Test func approvalMergesTheSeenHead() async throws {
        let store = try await registered(WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit))
        let transport = StubTransport([
            .json(200, Self.pullRequest()),
            .json(200, #"{"sha":"\#(String(repeating: "9", count: 40))","merged":true,"message":"merged"}"#)
        ])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        #expect(try await ApproveSetupPullRequestHandler(admin: admin).handle(approveEnvelope(), in: context(store)) == .accept)
        #expect(try await repository(in: store)?.setup?.workflows?.state == .merged)
        let merge = try #require(transport.bodies.last)
        #expect(merge["sha"] == .string(Self.commit))
        #expect(merge["merge_method"] == .string("merge"))
    }

    @Test func approvalRefusesChangedOrUnknownPullRequest() async throws {
        let store = try await registered(WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit))
        let transport = StubTransport([.json(200, Self.pullRequest(head: String(repeating: "d", count: 40)))])
        let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: transport)
        let handler = ApproveSetupPullRequestHandler(admin: admin)
        // 承認した後に push された
        #expect(try await handler.handle(approveEnvelope(), in: context(store)) == .reject("承認した後に準備の PR が更新された。見直して承認し直す"))
        // 司令塔が出していない PR・見たときと違う head は、GitHub に送らずに断る
        #expect(try await handler.handle(approveEnvelope(number: 13), in: context(store))
            == .reject("PR #13 は、司令塔が出した準備の PR でない"))
        let other = approveEnvelope(head: String(repeating: "e", count: 40))
        #expect(try await handler.handle(other, in: context(store)) == .reject("承認したときと準備の PR が違う（今は open）。見直して承認し直す"))
        #expect(transport.requests.count == 1)
        #expect(try await repository(in: store)?.setup?.workflows?.state == .open)
    }
}
