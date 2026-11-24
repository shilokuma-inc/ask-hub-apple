import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 準備をやり直したとき（`addRepository` の再送）に、開いている準備の PR を今の中身に合わせる
/// （`docs/renewal/operations.md` の「対象に加えるときの GitHub 側の準備」）
extension RepositorySetupRunner {
    /// 今の base の head から作った、準備の PR の中身
    struct Planned {
        /// 直すファイル（パス → 新しい中身。外すファイルは nil）
        var changes: [String: String?]
        /// 直しのコミットの親（中身を読んだ base の head）
        var parent: String
        var summary: [WorkflowChange]
        var adoption: AppKitAdoption?
        /// PR の題と本文
        var draft: PullRequestDraft
    }

    /// 開いている準備の PR を、今の base の head から作り直した中身（`planned`）に合わせる。
    ///
    /// - 中身（tree）が同じなら、ブランチも PR も変えない（承認を結びつけた head を変えない）
    /// - 違えば、作業ブランチ `askhub/setup-workflows` だけを base の head の上の 1 コミットに作り直し（force）、PR の題と本文を今の中身にする。
    ///   head が変わるので、前の head への承認ではマージしない（`ApproveSetupPullRequestHandler`）
    /// - app-kit の版を読めなかった・直すところが無くなったときは、作り直さずに開いている PR を残す
    func rebuild(
        _ open: PullRequest,
        to planned: Planned,
        previous: WorkflowSetup?,
        checked: Checked
    ) async throws(PullRequestError) -> Checked {
        var checked = checked
        let same = previous?.pullRequest == open.number
        let kept = WorkflowSetup(
            state: .open,
            pullRequest: open.number,
            head: open.headSHA,
            changes: same ? previous?.changes ?? [] : [],
            appKit: same ? previous?.appKit : nil
        )
        if checked.unreadAppKit {
            checked.setup = kept
            return checked
        }
        guard !planned.changes.isEmpty else {
            checked.setup = kept
            checked.problems.append("開いている準備の PR #\(open.number) は、今の base では直すところが無い。GitHub で閉じてから準備をやり直す")
            return checked
        }
        let rebuilt = try await github.recommitChanges(
            planned.changes,
            onto: planned.parent,
            branch: SetupPolicy.workflowBranch,
            replacing: open.headSHA,
            message: Self.commitMessage(planned.adoption?.version)
        )
        let setup = WorkflowSetup(
            state: .open, pullRequest: open.number, head: rebuilt ?? open.headSHA, changes: planned.summary, appKit: planned.adoption
        )
        // 作り直した・記録が今の中身と違う（前の作り直しが本文を書き換える前に止まった など）なら、題と本文も今の中身にする
        if rebuilt != nil || previous != setup {
            try await github.updatePullRequest(number: open.number, title: planned.draft.title, body: planned.draft.body)
        }
        checked.setup = setup
        return checked
    }
}
