@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import Foundation
import os

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
        var required: [Set<String>?] = []
        var branches: [String: String] = [:]
        /// `<base>...<head>` → 進んでいるコミットの数（無ければ 0）
        var ahead: [String: Int] = [:]
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

    func checks(_ repo: RepositoryFullName, at sha: String, required: Set<String>?) async throws(PullRequestError) -> CheckSummary {
        call { state in
            state.required.append(required)
            return state.checks
        }
    }

    func merge(_ repo: RepositoryFullName, number: Int, headSHA: String) async throws(PullRequestError) -> MergedPullRequest {
        call { state in
            state.merged.append(number)
            state.pull?.merged = true
            state.pull?.state = .closed
            return MergedPullRequest(sha: nil, mergedNow: true)
        }
    }

    func branchHead(_ repo: RepositoryFullName, branch: String) async throws(PullRequestError) -> String? {
        call { $0.branches[branch] }
    }

    func createBranch(_ repo: RepositoryFullName, branch: String, at sha: String) async throws(PullRequestError) -> String {
        call { state in
            if let head = state.branches[branch] { return head }
            state.branches[branch] = sha
            return sha
        }
    }

    func compare(_ repo: RepositoryFullName, base: String, head: String) async throws(PullRequestError) -> (ahead: Int, behind: Int) {
        call { state in (state.ahead["\(base)...\(head)"] ?? 0, 0) }
    }
}
