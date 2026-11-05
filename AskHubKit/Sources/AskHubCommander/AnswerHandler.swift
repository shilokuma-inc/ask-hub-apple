import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 回答・説明を求める（`answer`）を受け付ける（`docs/renewal/flows.md` の「司令塔の動き」の表）。
///
/// 書く順は、ジョブ → epic → 質問の一覧。質問の一覧を書いた時点で受け付けたことになる。
/// 途中で止まって次の周でやり直しても、ジョブは同じ id で作るので 2 つにならず、質問の一覧がすでにこの意図を受けていれば何もしない
public struct AnswerHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let answer: AnswerIntent
        do {
            answer = try AnswerIntent(envelope: envelope)
        } catch {
            return .reject(QuestionFlow.Rejection.malformed(error.detail).reason)
        }
        let epicPath = StatePath.epic(answer.repo, answer.epic)
        let questionsPath = StatePath.questions(answer.repo, answer.epic)
        guard let epic = try await read(EpicFile.self, at: epicPath, in: context),
              let questions = try await read(QuestionsFile.self, at: questionsPath, in: context) else {
            return .reject("epic か質問の一覧が無い")
        }
        if Self.alreadyApplied(answer, to: questions) { return .accept }
        let change: QuestionFlow.Change
        do {
            change = try QuestionFlow.accept(answer, epic: epic, questions: questions, at: context.timestamp)
        } catch {
            return .reject(error.reason)
        }
        try await perform(change.effects, for: answer, epic: epic, in: context)
        try await write(change.questions, replacing: questions, at: questionsPath, in: context)
        return .accept
    }

    /// 質問の一覧が、すでにこの意図を受けている（前の周で書いたが、処理した記録を書く前に止まった）
    static func alreadyApplied(_ answer: AnswerIntent, to questions: QuestionsFile) -> Bool {
        guard let question = questions.questions.first(where: { $0.id == answer.question }) else { return false }
        switch answer.mode {
        case .answer: return question.answer?.intent == answer.intent
        case .clarify: return question.explanations.contains { $0.asked == answer.intent }
        }
    }

    /// 司令塔がすることを行う。どれも、やり直しても結果が変わらない
    private func perform(
        _ effects: [QuestionFlow.Effect],
        for answer: AnswerIntent,
        epic: EpicFile,
        in context: CommanderContext
    ) async throws(CommanderError) {
        let repo = answer.repo
        for effect in effects {
            switch effect {
            case let .explain(question, asked):
                let input: [String: JSONValue] = ["question": .string(question), "asked": JSONValue.encoding(asked) ?? .null]
                try await context.create(context.claudeJob(.explain, for: epic, origin: asked, seed: question, input: input))
            case let .revise(question, basis):
                let input: [String: JSONValue] = ["question": .string(question), "basis": JSONValue.encoding(basis) ?? .null]
                let dependencies = basis.dependencies.map { "\($0.id):\($0.version):\($0.answer?.nonce.rawValue ?? "-")" }
                let seed = "\(question)/\(basis.version)/\(dependencies.joined(separator: ","))"
                try await context.create(context.claudeJob(.reviseQuestion, for: epic, origin: answer.intent, seed: seed, input: input))
            case let .cancel(question):
                try await context.cancelJobs(repo, epic: epic.id) { job in
                    [.explain, .reviseQuestion].contains(job.kind) && job.input?["question"]?.stringValue == question
                }
            case .reopen:
                // 着手前の確認とゴールの修正をやめ、回答に戻す
                try await context.cancelJobs(repo, epic: epic.id) { [.checkReadiness, .reviseGoal].contains($0.kind) }
                try await setStage(.asking, of: epic, in: context)
            case .checkReadiness:
                try await context.create(context.claudeJob(.checkReadiness, for: epic, origin: answer.intent, seed: "", input: [:]))
                try await setStage(.checking, of: epic, in: context)
            }
        }
    }

    private func setStage(_ stage: EpicStage, of epic: EpicFile, in context: CommanderContext) async throws(CommanderError) {
        let now = context.timestamp
        do {
            try await context.files.update(EpicFile.self, at: StatePath.epic(epic.repo, epic.id), message: "epic を \(stage.rawValue) にする") {
                guard $0.stage != stage else { return false }
                $0.stage = stage
                $0.updatedAt = now
                return true
            }
        } catch {
            throw .files(error)
        }
    }

    /// 読んだときのままなら書く。ほかの書き込みで変わっていたら、次の周でやり直す
    private func write(
        _ questions: QuestionsFile,
        replacing previous: QuestionsFile,
        at path: String,
        in context: CommanderContext
    ) async throws(CommanderError) {
        var changed = false
        do {
            try await context.files.update(QuestionsFile.self, at: path, message: "回答を受け付ける") { current in
                guard current == previous else { return false }
                current = questions
                changed = true
                return true
            }
        } catch {
            throw .files(error)
        }
        guard changed else { throw .changedWhileProcessing(path) }
    }

    private func read<File: StateFile>(
        _ type: File.Type,
        at path: String,
        in context: CommanderContext
    ) async throws(CommanderError) -> File? {
        do {
            return try await context.files.read(File.self, at: path)?.file
        } catch {
            throw .files(error)
        }
    }
}
