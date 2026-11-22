import AskHubClient
import AskHubProtocol
import Foundation

// MARK: - 「対処が要ります」の操作

extension StateIntentMapper {
    /// 人に渡されたジョブへの操作。人が見たときの試行の番号を付ける（その後に試行が進んでいれば、司令塔が断る）。
    /// 送り直すまでに「対処が要ります」に出すジョブが替わっていたら、別のジョブに当てないよう送らない
    func blockerDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .resolveBlocker(epicID, action, _, target):
            let job = try blockedJob(epicID: epicID, action: action, target: target)
            switch action {
            case .retry, .resumeAfterFix:
                return .retry(job)

            case .cancelJob, .discard:
                return .giveUp(job)

            // タスクを飛ばすのは、理由を付けて `HumanIntent.skipTask` で送る
            case .fixWithInstruction, .handOver, .pause, .skipTask:
                throw Self.unsupported
            }

        case let .skipTask(epicID, reason, note, target):
            let job = try blockedJob(epicID: epicID, action: .skipTask, target: target)
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            // 司令塔（`PayloadReader`）と同じく、Unicode のコードポイントで数える
            guard text.unicodeScalars.count <= SkipTaskIntent.maximumNoteLength else {
                throw ClientServiceError(message: "メモは \(SkipTaskIntent.maximumNoteLength) 文字までです")
            }
            return .skipTask(job, reason: reason == .handledElsewhere ? .handledElsewhere : .notNeeded, note: text)

        default:
            throw Self.unsupported
        }
    }

    /// 「対処が要ります」の操作。最後に読んだ状態の「対処が要ります」に出した操作だけ送れる
    func supportsBlockerIntent(_ intent: HumanIntent) -> Bool {
        switch intent {
        case let .resolveBlocker(epicID, action, _, _):
            index.epics[epicID]?.blockerActions.contains(action) == true

        case let .skipTask(epicID, _, _, _):
            index.epics[epicID]?.blockerActions.contains(.skipTask) == true

        default:
            false
        }
    }

    /// 「対処が要ります」に出したジョブ。送り直すまでに出すジョブが替わっていたら、別のジョブに当てないよう送らない
    private func blockedJob(epicID: Epic.ID, action: Blocker.Action, target: String?) throws(ClientServiceError) -> JobTarget {
        let entry = try epic(epicID)
        guard let job = entry.blockedJob else {
            throw ClientServiceError(message: "対処を待っている作業がありません。取り直してから送ってください")
        }
        guard target == StateSnapshotBuilder.blockerTarget(job), entry.blockerActions.contains(action) else {
            throw ClientServiceError(message: "対処を待っている作業が替わりました。画面を確かめてから選び直してください")
        }
        return job
    }
}
