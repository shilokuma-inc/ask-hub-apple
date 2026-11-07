import AskHubEpics
import AskHubProtocol
import Foundation

/// やり直しの人の意図（`retry`）を受け付け、人に渡したジョブを `assigned` に戻す（`docs/renewal/architecture.md` の「失敗の扱い」）。
///
/// 試行の番号（`targetVersion`）が、人が見たときのままのときだけ受け付ける。次の試行は担当の Mac がそのまま引き受ける。
/// 試行の失敗の数え方は変えないので、続けて同じ失敗をすれば、また人に渡る
public struct RetryJobHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let retry: RetryJobIntent
        do {
            retry = try RetryJobIntent(envelope: envelope)
        } catch {
            return .reject("やり直しの形が違う（\(error.detail)）")
        }
        // 前の周で戻した（やり直し）か、人に渡した後に元の試行が成功した
        switch try await WaitingJob.read(retry.target, done: [.assigned, .running, .succeeded], in: context) {
        case let .rejected(reason):
            return .reject(reason)
        case .done:
            return .accept
        case let .waiting(job, _):
            let now = context.timestamp
            try await WaitingJob.write(job, message: "ジョブ \(job.kind.rawValue) をやり直す", in: context) {
                $0.state = .assigned
                $0.nextRunAt = nil
                $0.updatedAt = now
            }
            return .accept
        }
    }
}

/// 人の対応を待っている（`waitingHuman` の）ジョブを対象にする意図の、対象の読み方と書き方
enum WaitingJob {
    case waiting(JobFile, EpicFile)
    /// ジョブが `done` の状態。前の周で済んでいる
    case done(JobFile, EpicFile)
    case rejected(String)

    /// 対象のジョブと epic を読む
    static func read(_ target: JobTarget, done: Set<JobState>, in context: CommanderContext) async throws(CommanderError) -> Self {
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(target.repo, target.epic)) else {
            return .rejected("epic が無い")
        }
        guard let job = try await context.read(JobFile.self, at: StatePath.job(target.repo, epic: target.epic, job: target.job)) else {
            return .rejected("ジョブが無い")
        }
        guard job.attempts == target.attempt else { return .rejected("試行の番号が今のジョブと違う（今は \(job.attempts)）") }
        if done.contains(job.state) { return .done(job, epic) }
        guard !epic.isFinished else { return .rejected("epic はもう終わっている（\(epic.stage.rawValue)）") }
        guard job.state == .waitingHuman else { return .rejected("ジョブは人の対応を待っていない（\(job.state.rawValue)）") }
        return .waiting(job, epic)
    }

    /// 読んだときのままのジョブだけを書き換える。読んだ後に書き換わっていれば、次の周で読み直して決める
    static func write(
        _ job: JobFile,
        message: String,
        in context: CommanderContext,
        change: @escaping @Sendable (inout JobFile) -> Void
    ) async throws(CommanderError) {
        let path = StatePath.job(job.repo, epic: job.epic, job: job.id)
        var written = false
        do {
            try await context.files.update(JobFile.self, at: path, message: message) {
                guard $0 == job else { return false }
                change(&$0)
                written = true
                return true
            }
        } catch {
            throw .files(error)
        }
        guard written else { throw .changedWhileProcessing(path) }
    }
}

/// やめる人の意図（`giveUp`）を受け付ける（`docs/renewal/flows.md` の「人に渡したジョブ」）。種類ごとの扱いは `JobKind.giveUpEffect` で決める
///
/// - 質問づくり・質問の見直し・着手前の確認: epic が先に進めないので、epic ごとやめる（`abandoned`）。epic の段階の 1 回の書き込みで決まる
/// - 説明: ジョブをやめ、説明を待つ問いを外して、質問を回答待ちに戻す
/// - ゴールの修正: ジョブだけやめる（前のゴールのまま開始を待つ）
public struct GiveUpJobHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let giveUp: GiveUpJobIntent
        do {
            giveUp = try GiveUpJobIntent(envelope: envelope)
        } catch {
            return .reject("やめるの形が違う（\(error.detail)）")
        }
        let target = giveUp.target
        let path = StatePath.job(target.repo, epic: target.epic, job: target.job)
        guard let job = try await context.read(JobFile.self, at: path) else { return .reject("ジョブが無い") }
        guard let effect = job.kind.giveUpEffect else { return .reject("\(job.kind.rawValue) のジョブをやめる扱いは、まだ決めていない") }
        if effect == .abandonsEpic { return try await abandonEpic(target, in: context) }
        switch try await WaitingJob.read(target, done: [.canceled], in: context) {
        case let .rejected(reason):
            return .reject(reason)
        case let .done(job, epic):
            try await reopenQuestion(of: job, epic: epic, in: context)
        case let .waiting(job, epic):
            let now = context.timestamp
            try await WaitingJob.write(job, message: "ジョブ \(job.kind.rawValue) をやめる", in: context) {
                $0.state = .canceled
                $0.nextRunAt = nil
                $0.updatedAt = now
            }
            try await reopenQuestion(of: job, epic: epic, in: context)
        }
        return .accept
    }

    /// epic ごとやめる。前の周でやめていれば（ジョブの片付けの途中で止まった）、片付けだけをする
    private func abandonEpic(_ target: JobTarget, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        switch try await WaitingJob.read(target, done: [], in: context) {
        case let .rejected(reason):
            guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(target.repo, target.epic)), epic.stage == .abandoned,
                  let job = try await context.read(JobFile.self, at: StatePath.job(target.repo, epic: target.epic, job: target.job)),
                  job.attempts == target.attempt, [.waitingHuman, .canceled].contains(job.state) else {
                return .reject(reason)
            }
            try await context.cancelJobs(epic.repo, epic: epic.id) { _ in true }
            return .accept
        case let .waiting(_, epic), let .done(_, epic):
            try await context.setStage(.abandoned, of: epic, from: CommanderContext.planningStages)
            try await context.cancelJobs(epic.repo, epic: epic.id) { _ in true }
            return .accept
        }
    }

    /// 説明のジョブをやめたら、説明を待つ問いを外して質問を回答待ちに戻す。当てはまらなければ（答え直した・前の周で戻した）何もしない
    private func reopenQuestion(of job: JobFile, epic: EpicFile, in context: CommanderContext) async throws(CommanderError) {
        guard job.kind == .explain, !epic.isFinished,
              let question = ClaudeJobRunner.input("question", of: job, as: String.self),
              let asked = ClaudeJobRunner.input("asked", of: job, as: IntentReference.self),
              let questions = try await context.read(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id)),
              let change = try? QuestionFlow.abandonExplanation(question, asked: asked, in: questions) else {
            return
        }
        try await context.write(change.questions, replacing: questions, of: epic, message: "説明をやめる（\(question)）")
    }
}

extension EpicFile {
    /// マージした・やめた epic
    var isFinished: Bool { [.merged, .abandoned].contains(stage) }
}
