import AskHubProtocol
import Foundation

// MARK: - 送った意図が働きかける画面の要素

extension StateSnapshotBuilder {
    /// 送った意図が働きかける画面の要素（画面の意図から決める `HumanIntent.targets` と同じ対象にする）。画面の要素に結びつかなければ nil
    static func target(of envelope: IntentEnvelope) -> IntentTarget? {
        guard envelope.kind != RequestIntent.kind else {
            return .request(epicID: epicID(forRequest: envelope).rawValue)
        }
        return target(kind: envelope.kind, repo: envelope.repo, target: envelope.target)
    }

    /// 意図の種類と対象から決める画面の要素。依頼は、作られる epic の id が意図の番号で決まるので、ここでは決めない（nil）
    static func target(kind: String, repo: RepositoryFullName?, target: IntentEnvelope.Target?) -> IntentTarget? {
        switch kind {
        case RequestIntent.kind:
            return nil

        case AddRepositoryIntent.kind, RemoveRepositoryIntent.kind:
            return repo.map { .repository(repository($0).id) }

        case PublishGitHubReleaseIntent.kind:
            // 配信した版は epic に属さないので、リポジトリと版（`target.id`）で決める
            guard let repo, target?.type == ReleaseTarget.targetType, let version = target?.id else {
                return nil
            }
            return .release(repositoryID: repository(repo).id, version: version)

        default:
            guard let epicID = target?.epic?.rawValue else {
                return nil
            }
            if let id = target?.id, let item = itemTarget(kind: kind, epicID: epicID, id: id) {
                return item
            }
            return epicTarget(kind: kind, epicID: epicID)
        }
    }

    /// epic の中の 1 つ（質問・判断のカード・人がする作業）を対象にする意図の対象
    private static func itemTarget(kind: String, epicID: Epic.ID, id: String) -> IntentTarget? {
        switch kind {
        case AnswerIntent.kind:
            .question(epicID: epicID, questionID: displayID(id))

        case DecisionIntent.kind:
            .decision(epicID: epicID, decisionID: id)

        case HumanTaskDoneIntent.kind:
            .humanTask(epicID: epicID, taskID: id)

        case VerifyIntent.kind:
            .verification(epicID: epicID, itemID: id)

        default:
            nil
        }
    }

    /// epic の全体（ゴール・分け方・最終 PR・対処・epic の操作）を対象にする意図の対象。ジョブを対象にする意図は「対処が要ります」に出す
    private static func epicTarget(kind: String, epicID: Epic.ID) -> IntentTarget? {
        switch kind {
        case StartEpicIntent.kind, ReviseGoalIntent.kind:
            .goal(epicID: epicID)

        case DecideSplitIntent.kind:
            .split(epicID: epicID)

        case ApproveMergeIntent.kind, InstructFinalIntent.kind:
            .finalPullRequest(epicID: epicID)

        case RetryJobIntent.kind, GiveUpJobIntent.kind:
            .blocker(epicID: epicID)

        case AbandonEpicIntent.kind, PauseEpicIntent.kind, ResumeEpicIntent.kind, HandoverIntent.kind:
            .epicControl(epicID: epicID)

        default:
            nil
        }
    }
}
