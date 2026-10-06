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
        let status = statuses[key] ?? .idle
        let pending = pendingDecisionResumes[key].flatMap { $0.issueNumber == issue.number ? $0 : nil }
        if let pending, !confirmIfLoopStarted(pending, status: status, in: repository) {
            return
        }
        // 動いているループは自分で処理する。異常終了したループは resumeStalledLoops が再開する
        guard !status.processAlive, status.stateFileExists == false, !status.stalled else {
            return
        }
        let comments = try await github.comments(in: issue.repository, issue: issue.number)
        let instructions = DecisionLog.unprocessedInstructions(in: comments, trustedAuthors: config.trustedAuthors)
        let attempts = pending.map { settleUnconfirmedResume($0, instructions: instructions, in: repository) } ?? 0
        guard let latest = instructions.last else {
            return
        }
        // ループが返信せずに終えても、同じコメントでは 1 回しか再開しない
        let commentKey = "\(key)#\(latest.id)"
        guard !resumedDecisionComments.contains(commentKey) else {
            return
        }
        guard await runtime.epicSnapshot(of: repository).branch == branch else {
            pendingDecisionResumes[key] = nil
            resumedDecisionComments.insert(commentKey)
            log("\(repository.fullName)#\(issue.number) の仮決め一覧に指示が付きましたが、制御用 worktree が \(branch) ではないのでループを再開できません")
            return
        }
        do {
            // 再開では Discussion を伴わないので `{discussion}` は空になる。
            // epic のタスクがすべて完了していても起動するよう、起動スクリプトに再開の理由を渡す
            try await runtime.launch(
                config.loopCommand.render(for: repository),
                environment: [Self.resumeReasonVariable: Self.decisionLogResumeReason],
                for: repository
            )
        } catch {
            log("\(repository.fullName) のループを仮決め一覧の指示で再開できませんでした（次のポーリングで再試行します）: \(error)")
            return
        }
        // ループの開始を確かめてから、処理済みとして覚え、最終 PR の書き直しの対象にする
        pendingDecisionResumes[key] = DecisionLogResume(
            issueNumber: issue.number,
            commentID: latest.id,
            commentKey: commentKey,
            epicKey: "\(key) \(branch)",
            attempts: attempts + 1
        )
        statuses[key] = LoopStatus(stateFileExists: false, processAlive: true)
        log("\(repository.fullName)#\(issue.number) の仮決め一覧に指示が付いたので、ループを再開しました")
    }

    /// 起動したループの開始を state ファイルで確かめる。
    /// 起動したプロセスが state ファイルを作らないまま終わっていて、続けて判断してよいときは `true`
    private func confirmIfLoopStarted(_ pending: DecisionLogResume, status: LoopStatus, in repository: RepositoryConfig) -> Bool {
        if status.stateFileExists == true {
            // ループが始まった。指示はループが周回の最初に読む（異常終了していれば resumeStalledLoops が再開する）
            confirmDecisionResume(pending, in: repository)
            return false
        }
        // 起動スクリプトの準備中など、まだ確かめられなければ待つ
        return !status.processAlive && status.stateFileExists == false
    }

    /// 起動したプロセスが、state ファイルを確かめる前に終わった。続けて起動するときの、これまでの起動回数を返す
    private func settleUnconfirmedResume(
        _ pending: DecisionLogResume,
        instructions: [IssueComment],
        in repository: RepositoryConfig
    ) -> Int {
        let name = "\(repository.fullName)#\(pending.issueNumber)"
        if !instructions.contains(where: { $0.id == pending.commentID }) {
            // その間にループが指示に返信している（ポーリングの間に始まって終わった）ので、ループは動いた
            confirmDecisionResume(pending, in: repository)
            return 0
        }
        if pending.attempts >= Self.maxDecisionResumeAttempts {
            pendingDecisionResumes[repository.fullName.lowercased()] = nil
            resumedDecisionComments.insert(pending.commentKey)
            log("\(name) の仮決め一覧の指示でループの開始を \(pending.attempts) 回確かめられませんでした。"
                + "この指示では再開しません（loopCommand と起動スクリプトのログを確認してください）")
            return 0
        }
        // 起動スクリプトがループを始めずに終わった（タスクが無いと判断した・途中で失敗したなど）。最終 PR は書き直さない
        log("\(name) の仮決め一覧の指示で起動したループの開始を確かめられないまま、プロセスが終わりました"
            + "（\(pending.attempts)/\(Self.maxDecisionResumeAttempts) 回目）。再開し直します")
        return pending.attempts
    }

    /// 仮決め一覧の指示で起動したループの開始を確かめた。指示を処理済みとして覚え、ループが再び完了したら最終 PR の本文を書き直す
    private func confirmDecisionResume(_ pending: DecisionLogResume, in repository: RepositoryConfig) {
        pendingDecisionResumes[repository.fullName.lowercased()] = nil
        resumedDecisionComments.insert(pending.commentKey)
        finalizedEpics.remove(pending.epicKey)
        epicsToRefresh.insert(pending.epicKey)
        log("\(repository.fullName)#\(pending.issueNumber) の仮決め一覧の指示で再開したループの開始を確かめました")
    }

    /// 起動スクリプトに再開の理由を伝える環境変数
    static let resumeReasonVariable = "ASKHUB_RESUME_REASON"
    /// 仮決め一覧への指示による再開。起動スクリプトは、未完了のタスクが無くてもループを起動する
    static let decisionLogResumeReason = "decision-log"
    /// 仮決め一覧の指示で、ループの開始を確かめられないまま起動を試す回数の上限
    static let maxDecisionResumeAttempts = 3
}

/// 仮決め一覧への指示で起動し、開始をまだ確かめていないループ
struct DecisionLogResume: Sendable, Equatable {
    /// 仮決め一覧の Issue の番号
    let issueNumber: Int
    /// 再開のきっかけになったコメントの id
    let commentID: Int
    /// `resumedDecisionComments` のキー（`<repo小文字>#<コメント id>`）
    let commentKey: String
    /// `epicsToRefresh` / `finalizedEpics` のキー（`<repo小文字> <branch>`）
    let epicKey: String
    /// 起動した回数
    let attempts: Int
}
