import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 回答・説明を求める（`answer`）を受け付ける（`docs/renewal/flows.md` の「司令塔の動き」の表）。
/// 開始した後も、実装の途中の質問には受け付け、答えたら質問したジョブを再開するジョブを作る（「実装の途中の質問」）。
///
/// 書く順は、ジョブ → epic → 質問の一覧。質問の一覧を書いた時点で受け付けたことになる。
/// 途中で止まって次の周でやり直しても、ジョブは同じ id で作るので 2 つにならず、質問の一覧がすでにこの意図を受けていれば何もしない。
/// ただし再開のジョブはほかの Mac のワーカーが引き受けるので、答えを質問の一覧に書いてから作る（書く前に動いて「答えが無い」で失敗しないように）
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
        if Self.alreadyApplied(answer, to: questions) {
            // 答えを書いた後、再開のジョブを作る前に止まった（同じ id で作るので 2 つにならない）
            try await context.perform(Self.resumption(of: answer, in: questions), for: epic, origin: answer.intent)
            return .accept
        }
        let change: QuestionFlow.Change
        do {
            change = try QuestionFlow.accept(answer, epic: epic, questions: questions, at: context.timestamp)
        } catch {
            return .reject(error.reason)
        }
        // 実装の途中の質問の答えは、質問したジョブを再開する。ジョブが読めなければ、再開できないので受け付けない
        for case let .resume(question, job) in change.effects {
            guard try await read(JobFile.self, at: StatePath.job(epic.repo, epic: epic.id, job: job), in: context) != nil else {
                return .reject("質問 \(question) をしたジョブ（\(job)）が無い")
            }
        }
        let resumptions = change.effects.filter { if case .resume = $0 { true } else { false } }
        try await context.perform(change.effects.filter { !resumptions.contains($0) }, for: epic, origin: answer.intent)
        // 同じ答えの送り直しなど、質問の一覧が変わらないときは書かない
        if change.questions != questions {
            try await context.write(change.questions, replacing: questions, of: epic, message: "回答を受け付ける")
        }
        try await context.perform(resumptions, for: epic, origin: answer.intent)
        return .accept
    }

    /// すでに受けた答えで再開するジョブ（実装の途中の質問への答えのときだけ）
    static func resumption(of answer: AnswerIntent, in questions: QuestionsFile) -> [QuestionFlow.Effect] {
        guard answer.mode == .answer, let question = questions.questions.first(where: { $0.id == answer.question }),
              let job = question.job else {
            return []
        }
        return [.resume(question: question.id, job: job)]
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
