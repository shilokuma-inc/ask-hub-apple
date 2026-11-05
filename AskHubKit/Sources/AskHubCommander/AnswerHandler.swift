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
        try await context.perform(change.effects, for: epic, origin: answer.intent)
        try await context.write(change.questions, replacing: questions, of: epic, message: "回答を受け付ける")
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
