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
                        try await resumeIfInstructed(by: issue, branch: branch, in: repository, statuses: &statuses)
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
            DecisionLog.isTrustedMarked($0, with: DecisionLog.closeMarker, trustedAuthors: config.trustedAuthors)
        }
        if !commented {
            let body = DecisionLog.closingComment(pullRequest: pullRequest, uncheckedItems: DecisionLog.uncheckedItems(in: issue.body))
            try await github.comment(on: issue, body: body)
        }
        try await github.close(issue)
        log("\(issue.repository) の最終 PR #\(pullRequest) がマージ済みなので、仮決め一覧 #\(issue.number) を閉じました")
    }

    /// 最終 PR のマージ待ち（ループは止まっている）の間に仮決め一覧へ指示が付いたら、ループを再開して処理させる
    private func resumeIfInstructed(
        by issue: DecisionLogIssue,
        branch: String,
        in repository: RepositoryConfig,
        statuses: inout [String: LoopStatus]
    ) async throws {
        let key = repository.fullName.lowercased()
        // 動いているループは自分で処理する。異常終了したループは resumeStalledLoops が再開する
        let status = statuses[key] ?? .idle
        guard !status.processAlive, status.stateFileExists == false, !status.stalled else {
            return
        }
        let comments = try await github.comments(in: issue.repository, issue: issue.number)
        guard let latest = DecisionLog.unprocessedInstructions(in: comments, trustedAuthors: config.trustedAuthors).last else {
            return
        }
        // ループが返信せずに終えても、同じコメントでは 1 回しか再開しない
        let commentKey = "\(key)#\(latest.id)"
        guard !resumedDecisionComments.contains(commentKey) else {
            return
        }
        guard await runtime.epicSnapshot(of: repository).branch == branch else {
            resumedDecisionComments.insert(commentKey)
            log("\(repository.fullName)#\(issue.number) の仮決め一覧に指示が付きましたが、制御用 worktree が \(branch) ではないのでループを再開できません")
            return
        }
        do {
            // 再開では Discussion を伴わないので `{discussion}` は空になる
            try await runtime.launch(config.loopCommand.render(for: repository), for: repository)
        } catch {
            log("\(repository.fullName) のループを仮決め一覧の指示で再開できませんでした（次のポーリングで再試行します）: \(error)")
            return
        }
        resumedDecisionComments.insert(commentKey)
        // ループが再び完了したら、最終 PR の本文を書き直す
        let epicKey = "\(key) \(branch)"
        finalizedEpics.remove(epicKey)
        epicsToRefresh.insert(epicKey)
        statuses[key] = LoopStatus(stateFileExists: false, processAlive: true)
        log("\(repository.fullName)#\(issue.number) の仮決め一覧に指示が付いたので、ループを再開しました")
    }
}
