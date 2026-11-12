@testable import AskHubCommander
import AskHubPullRequests
import Foundation

/// GitHub Actions の実行の読み取りと、PR の閉じる・開き直す（`FakePullRequests` の続き）
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
            state.stateChanges.append((number, newState))
            state.pulls[number]?.state = newState
            return .success(())
        }
        try result.get()
    }
}
