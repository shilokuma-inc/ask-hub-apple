import AskHubProtocol
import Foundation

// MARK: - タスクを飛ばす

extension StateSnapshotBuilder {
    /// タスクを飛ばした: 受け取りまでの間も、タスクを飛ばしたものとして出す（司令塔は済んだものとして次のタスク・最終 PR へ進める）
    func skipTask(of job: JobFile, envelope: IntentEnvelope, in epic: inout Epic) {
        guard let taskID = job.task, let skip = try? SkipTaskIntent(envelope: envelope) else {
            return
        }
        if let index = epic.tasks.firstIndex(where: { $0.id == taskID }) {
            epic.tasks[index].state = .skipped(reason: Self.skipReason(skip.reason, note: skip.note))
        }
        let text = "\(taskName(taskID, epic: job.epic) ?? "タスク \(taskID)")を飛ばしました。司令塔が受け取るのを待っています"
        epic.history.append(Epic.HistoryEntry(date: envelope.issuedAt.date, text: text))
    }

    /// 画面の飛ばした理由（メモがあれば添える）
    static func skipReason(_ reason: TaskSkipReason, note: String?) -> String {
        let label = switch reason {
        case .handledElsewhere: TaskSkip.handledElsewhere.label
        case .notNeeded: TaskSkip.notNeeded.label
        }
        guard let note, !note.isEmpty else {
            return label
        }
        return "\(label)・\(note)"
    }
}
