import AskHubKit
import Foundation

// 仮決め一覧（decision-log）の扱い。最終 PR のマージで閉じ、マージ前に付いた指示ではループを再開する
extension Orchestrator {
    func handleDecisionLogs(statuses: inout [String: LoopStatus]) async {
        for repository in config.repositories {
            let issues: [DecisionLogIssue]
            do {
                issues = try await github.decisionLogs(in: repository.fullName)
            } catch {
                log("\(repository.fullName) の仮決め一覧を取得できませんでした: \(error)")
                continue
            }
            for issue in issues {
                // タイトルから epic が分からないもの（手で作ったものなど）は扱わない
                guard let branch = issue.branch else {
                    continue
                }
                // 1 件の失敗で、ほかの仮決め一覧の処理を止めない
                do {
                    guard let pull = try await github.existingPullRequest(in: repository.fullName, head: branch) else {
                        continue
                    }
                    if pull.isMerged {
                        try await closeDecisionLog(issue, pullRequest: pull.number)
                    } else if pull.isOpen {
                        let place = InstructionPlace(kind: .decisionLog, repository: issue.repository, number: issue.number, branch: branch)
                        try await resumeIfInstructed(at: place, in: repository, statuses: &statuses) { comments, trustedAuthors in
                            DecisionLog.unprocessedInstructions(in: comments, trustedAuthors: trustedAuthors)
                        }
                    }
                } catch {
                    log("\(repository.fullName)#\(issue.number) の仮決め一覧を処理できませんでした（次のポーリングで再試行します）: \(error)")
                }
            }
        }
    }

    /// 仮決め一覧への指示でループを再開した epic は、「最終 PR に載せる内容」が変わっているので本文を書き直す。
    /// 書き直したら `true`（本文にはゴール元の Discussion の目印も入る）
    func rewriteFinalPullRequestIfResumed(
        _ pull: ExistingPullRequest,
        key: String,
        summary: String,
        snapshot: EpicSnapshot,
        in repository: RepositoryConfig
    ) async throws -> Bool {
        guard epicsToRefresh.contains(key) else {
            return false
        }
        let body = EpicSnapshot.pullRequestBody(summary: summary, discussion: snapshot.discussion)
        try await github.updatePullRequestBody(
            in: repository.fullName,
            number: pull.number,
            body: body + GitHubOrchestrator.epicFinalFooter
        )
        epicsToRefresh.remove(key)
        log("\(repository.fullName) の最終 PR #\(pull.number) の本文を、再開したループの結果で書き直しました")
        return true
    }

    /// 最終 PR がマージされた仮決め一覧を閉じる。返答の無かった仮決めは既定値のまま確定したと書き残す
    private func closeDecisionLog(_ issue: DecisionLogIssue, pullRequest: Int) async throws {
        // コメントした後にクローズだけ失敗していたら、コメントを重ねない
        let comments = try await github.comments(in: issue.repository, issue: issue.number)
        let commented = comments.contains {
            DecisionLog.isTrustedMarked($0, with: DecisionLog.closeMarker, trustedAuthors: trust.authors(for: issue.repository))
        }
        if !commented {
            let body = DecisionLog.closingComment(pullRequest: pullRequest, uncheckedItems: DecisionLog.uncheckedItems(in: issue.body))
            try await github.comment(on: issue, body: body)
        }
        try await github.close(issue)
        log("\(issue.repository) の最終 PR #\(pullRequest) がマージ済みなので、仮決め一覧 #\(issue.number) を閉じました")
    }
}
