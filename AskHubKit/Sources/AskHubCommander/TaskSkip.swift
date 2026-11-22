import AskHubProtocol
import Foundation

/// タスクを飛ばす人の意図（`skipTask`）を受け付ける（`docs/renewal/flows.md` の「人に渡したジョブ」）。
///
/// 人に渡した実装・レビュー・直しのジョブ（`running` の epic）のタスクを `skipped` にし、飛ばした記録（理由・メモ・意図・時刻・子 PR）を
/// `goal.json` に書いてから、同じタスクの終わっていないジョブを取り消す。その後は、いつもどおり `TaskFlow` が次のタスク・最終 PR の段取りに進める
/// （飛ばしたタスクは済んだものとして扱う）。飛ばしたときに開いていた子 PR は、最終 PR を出すときに閉じる（`OpenFinalPullRequestRunner`）
///
/// 途中で止まっても、次の周で同じ意図を処理し直せば続きをする（この意図で飛ばしたタスクなら、ジョブの取り消しだけをする）
public struct SkipTaskHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let skip: SkipTaskIntent
        do {
            skip = try SkipTaskIntent(envelope: envelope)
        } catch {
            return .reject("タスクを飛ばすの形が違う（\(error.detail)）")
        }
        let job: JobFile
        let epic: EpicFile
        switch try await WaitingJob.read(skip.target, done: [.canceled], in: context) {
        case let .rejected(reason):
            return .reject(reason)
        case let .waiting(found, owner), let .done(found, owner):
            (job, epic) = (found, owner)
        }
        guard job.kind.canSkipTask(at: epic.stage), let taskID = job.task else {
            return .reject("\(job.kind.rawValue) のジョブのタスクは飛ばせない（epic は \(epic.stage.rawValue)）")
        }
        let path = StatePath.goal(epic.repo, epic.id)
        guard let goal = try await context.read(GoalFile.self, at: path) else { return .reject("ゴールが無い") }
        guard let task = goal.tasks.first(where: { $0.id == taskID }) else { return .reject("タスク \(taskID) がゴールに無い") }
        // 前の周でこの意図が飛ばしたなら、ジョブの取り消しだけをする
        if task.skip?.intent != skip.intent {
            guard job.state == .waitingHuman else { return .reject("ジョブは人の対応を待っていない（\(job.state.rawValue)）") }
            guard task.state == .running else { return .reject("タスク \(taskID) は進めていない（\(task.state.rawValue)）") }
            if let problem = try await Self.problem(skipping: taskID, of: job, in: goal, context: context) { return .reject(problem) }
            let record = GoalFile.Skip(
                reason: skip.reason,
                note: skip.note.isEmpty ? nil : skip.note,
                intent: skip.intent,
                at: context.timestamp,
                pullRequest: Self.pullRequest(of: job)
            )
            try await write(record, to: taskID, at: path, in: context)
        }
        try await context.cancelJobs(epic.repo, epic: epic.id) { $0.task == taskID }
        return .accept
    }

    /// 飛ばせない理由。飛ばせれば nil
    /// - 子 PR をマージした後に止まったレビュー（子ブランチを消せなかった）: 変更は作業ブランチに入っている。「もう一度試す」で続きをする
    /// - 何も実装していないまま最後のタスクを飛ばす: 最終 PR に入れるものが無い
    static func problem(
        skipping taskID: String,
        of job: JobFile,
        in goal: GoalFile,
        context: CommanderContext
    ) async throws(CommanderError) -> String? {
        if job.kind == .reviewTask, job.attempts > 0,
           try await context.read(AttemptFile.self, at: StatePath.attempt(job.repo, epic: job.epic, job: job.id, number: job.attempts))?
               .outputs?.verdict == .merged {
            return "タスク \(taskID) の子 PR はもうマージした。飛ばさずに「もう一度試す」で続きをする"
        }
        if goal.skippingLeavesNothing(taskID) {
            return "タスク \(taskID) を飛ばすと、実装したタスクが 1 つも無く、最終 PR に入れるものが無い。epic ごとやめるなら「やめる」を選ぶ"
        }
        return nil
    }

    /// 飛ばすジョブが見ていた子 PR（レビュー・直しの入力）。実装のジョブは子 PR を作る前に止まるので nil
    static func pullRequest(of job: JobFile) -> Int? {
        switch job.kind {
        case .reviewTask: job.input(as: PullRequestInput.self)?.pullRequest
        case .fixTask: job.input(as: FixTaskInput.self)?.pullRequest
        default: nil
        }
    }

    /// タスクを `running` から `skipped` にして、飛ばした記録を書く。人が読むゴールの中身は変えないので、ゴールの版は上げない
    private func write(
        _ record: GoalFile.Skip,
        to taskID: String,
        at path: String,
        in context: CommanderContext
    ) async throws(CommanderError) {
        let saved: GoalFile
        do {
            saved = try await context.files.update(GoalFile.self, at: path, message: "タスク \(taskID) を飛ばす") { goal in
                guard let index = goal.tasks.firstIndex(where: { $0.id == taskID }), goal.tasks[index].state == .running else {
                    return false
                }
                goal.tasks[index].state = .skipped
                goal.tasks[index].skip = record
                return true
            }.file
        } catch {
            throw .files(error)
        }
        // 読んだ後に書き換わった（ほかの意図で飛ばした・タスクが進んだ）。次の周で読み直して決める
        guard saved.tasks.contains(where: { $0.id == taskID && $0.skip == record }) else { throw .changedWhileProcessing(path) }
    }
}

extension GoalFile.Skip {
    /// 人が読む理由（最終 PR の本文・Discussion の写し・Claude に渡すゴール）
    var text: String {
        let reason = switch reason {
        case .handledElsewhere: "人が別にやる"
        case .notNeeded: "やらない"
        }
        return note.map { "\(reason)。\($0)" } ?? reason
    }
}
