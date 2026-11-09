import AskHubProtocol
import Foundation

// MARK: - 送った意図が働きかける画面の要素

extension StateSnapshotBuilder {
    /// 送った意図が働きかける画面の要素（画面の意図から決める `HumanIntent.targets` と同じ対象にする）。画面の要素に結びつかなければ nil
    static func target(of envelope: IntentEnvelope) -> IntentTarget? {
        switch envelope.kind {
        case RequestIntent.kind:
            return .request(epicID: epicID(forRequest: envelope).rawValue)

        case AddRepositoryIntent.kind:
            return envelope.repo.map { .repository(repository($0).id) }

        default:
            guard let epicID = envelope.target?.epic?.rawValue else {
                return nil
            }
            if let id = envelope.target?.id, let target = itemTarget(kind: envelope.kind, epicID: epicID, id: id) {
                return target
            }
            return epicTarget(kind: envelope.kind, epicID: epicID)
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
