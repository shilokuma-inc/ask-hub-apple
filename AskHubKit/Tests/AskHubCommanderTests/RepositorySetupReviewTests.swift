@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 加えるときの準備で、ワークフローを読み違えない・失敗しても準備の PR の記録を消さない
extension RepositorySetupTests {
    /// 待つチェックの名前は、ジョブの id だけでなく表示名（`jobs.<id>.name`）とも照らす
    @Test func matchesWaitedChecksByJobDisplayName() {
        let lint = """
            name: CI
            on:
              pull_request:
                paths: ['Sources/**']
            jobs:
              ci:
                name: lint
                runs-on: macos-26
              docs:
                name: "${{ matrix.name }}"
                runs-on: ubuntu-latest
            """
        let plan = WorkflowSetupEditor.plan([WorkflowFile(path: ".github/workflows/ci.yml", text: lint)], waitedJobs: ["lint", "build"])
        #expect(plan.summary == [.init(kind: .removePathFilters, path: ".github/workflows/ci.yml")])
        // どのジョブにも見つからない待つチェックは、人が確かめるよう返す
        #expect(plan.unresolvedJobs == ["build"])
        #expect(WorkflowSetupEditor.jobNames(in: lint) == ["lint"])
    }

    /// 今の仕組みのワークフローは、`uses:` で ralph-kit を呼ぶものだけ。コメントに目印があるだけでは外さない
    @Test func legacyWorkflowIsFoundOnlyByUses() {
        let mentioned = """
            name: Build
            # ralph-kit から移した
            on: [push]
            jobs:
              build:
                runs-on: macos-26
                steps:
                  - run: echo ralph_kit
            """
        #expect(!WorkflowSetupEditor.isLegacy(WorkflowFile(path: ".github/workflows/build.yml", text: mentioned)))
        let step = """
            jobs:
              close:
                steps:
                  - uses: shilokuma-inc/Ralph-Kit/actions/close@main # 今の仕組み
            """
        #expect(WorkflowSetupEditor.isLegacy(WorkflowFile(path: ".github/workflows/close.yml", text: step)))
        let reusable = "jobs:\n  close:\n    uses: shilokuma-inc/ralph-kit/.github/workflows/close-goal.yml@main\n"
        #expect(WorkflowSetupEditor.isLegacy(WorkflowFile(path: ".github/workflows/goal.yml", text: reusable)))
    }

    /// `paths:` と同じ深さに書いたリストの値も一緒に外す（残すと YAML が壊れる）
    @Test func removesSameDepthListUnderPaths() throws {
        let text = """
            on:
              push:
                paths:
                - 'App/**'
                - 'Package.swift'
                branches:
                - develop
              pull_request:
                paths-ignore: ['**/*.md']

                types: [opened]
            jobs:
              build:
                runs-on: macos-26
            """
        let edited = try #require(WorkflowSetupEditor.removingPathFilters(text))
        #expect(edited == """
            on:
              push:
                branches:
                - develop
              pull_request:

                types: [opened]
            jobs:
              build:
                runs-on: macos-26
            """)
    }

    /// 準備が途中で失敗しても、前に出した準備の PR の記録は残す（消すと、その PR の承認を断ることになる）
    @Test func failedSetupKeepsWorkflowPullRequestRecord() async throws {
        let previous = WorkflowSetup(state: .open, pullRequest: 12, head: Self.commit)
        // 管理用のトークンが無い
        let missing = try await registered(previous)
        let none = AdminGitHub(tokens: AdminTokens { _ in nil }, transport: StubTransport([]))
        try await RepositorySetupStep(admin: none).run(for: Self.repo, in: context(missing))
        #expect(try await repository(in: missing)?.setup?.workflows == previous)
        // リポジトリの設定を読めない・ワークフローの直しで失敗した
        for replies in [
            [StubTransport.Reply.json(500, "{}")],
            [
                .json(200, #"{"default_branch":"develop","private":false,"has_discussions":true}"#),
                .data(#"{"repository":{"discussionCategories":{"nodes":[{"name":"Ideas"}]}}}"#),
                .json(500, "{}")
            ]
        ] {
            let store = try await registered(previous)
            let admin = AdminGitHub(tokens: AdminTokens { _ in ProtectionTests.adminToken }, transport: StubTransport(replies))
            try await RepositorySetupStep(admin: admin).run(for: Self.repo, in: context(store))
            let setup = try #require(try await repository(in: store)?.setup)
            #expect(setup.workflows == previous)
            #expect(setup.problems?.isEmpty == false)
        }
    }
}
