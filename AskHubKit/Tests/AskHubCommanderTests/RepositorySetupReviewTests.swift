@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

/// 加えるときの準備で、ワークフローを読み違えない
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
}
