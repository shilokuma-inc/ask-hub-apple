@testable import AskHubCommander
import AskHubPullRequests
import Foundation

/// GitHub Actions の実行の読み取りと、PR の閉じる・開き直す・コメント（`FakePullRequests` の続き）
extension FakePullRequests {
    func workflowRuns(at sha: String) async throws(PullRequestError) -> [WorkflowRun] {
        update { state in
            state.workflowRunReads += 1
            return state.workflowRuns.count > 1 ? state.workflowRuns.removeFirst() : state.workflowRuns[0]
        }
    }

    func jobCount(runID: Int) async throws(PullRequestError) -> Int {
        update { state in state.jobCounts[runID] ?? 1 }
    }

    func setState(number: Int, to newState: PullRequest.State) async throws(PullRequestError) {
        let result = update { state -> Result<Void, PullRequestError> in
            if newState == .open, !state.reopenFailures.isEmpty { return .failure(state.reopenFailures.removeFirst()) }
            let lost = newState == .closed && !state.closeFailures.isEmpty ? state.closeFailures.removeFirst() : nil
            if let lost, !lost.applied { return .failure(lost.error) }
            state.stateChanges.append((number, newState))
            state.pulls[number]?.state = newState
            return lost.map { .failure($0.error) } ?? .success(())
        }
        try result.get()
    }

    func comment(number: Int, body: String) async throws(PullRequestError) {
        let result = update { state -> Result<Void, PullRequestError> in
            if !state.commentFailures.isEmpty { return .failure(state.commentFailures.removeFirst()) }
            state.comments.append((number, body))
            return .success(())
        }
        try result.get()
    }

    func openPullRequests(head: String?, base: String?) async throws(PullRequestError) -> [PullRequest] {
        let result = update { state -> Result<[PullRequest], PullRequestError> in
            if !state.listFailures.isEmpty { return .failure(state.listFailures.removeFirst()) }
            let open = state.pulls.values.filter { pull in
                pull.state == .open && head.map { pull.headRef == $0 } ?? true && base.map { pull.baseRef == $0 } ?? true
            }
            return .success(open.sorted { $0.number < $1.number })
        }
        return try result.get()
    }
}
