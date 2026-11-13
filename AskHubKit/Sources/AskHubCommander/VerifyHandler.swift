import AskHubProtocol
import AskHubStateStore
import Foundation

/// 実機確認への答え（`verify`）を受け付け、`verifications.json` に記録する（`docs/renewal/flows.md` の「実機で確かめてほしいこと」）。
///
/// 答えられるのは、最終 PR をマージした epic の、ゴールの完了の条件の項目に 1 回だけ。
/// 「問題あり」の直しは、クライアントが同時に送る依頼が新しい epic になるので、ここでは記録するだけにする
public struct VerifyHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let verify: VerifyIntent
        do {
            verify = try VerifyIntent(envelope: envelope)
        } catch {
            return .reject("実機確認への答えの形が違う（\(error.detail)）")
        }
        let target = verify.target
        let path = StatePath.verifications(target.repo, target.epic)
        let current = try await context.read(VerificationsFile.self, at: path)
        if let answered = current?.answer(target.item) {
            // 前の周で記録した（やり直し）なら済んでいる。ほかの意図で答えていれば、答え直さない
            return answered.intent == verify.intent ? .accept : .reject("実機確認の項目 \(target.item) にはもう答えている")
        }
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(target.repo, target.epic)) else {
            return .reject("epic が無い")
        }
        guard epic.stage == .merged else { return .reject("最終 PR をマージした epic でない（今は \(epic.stage.rawValue)）") }
        guard let goal = try await context.read(GoalFile.self, at: StatePath.goal(target.repo, target.epic)) else {
            return .reject("ゴールが無い")
        }
        guard goal.version == target.goalVersion else { return .reject("ゴールの版が違う（今の版は \(goal.version)）") }
        guard let index = VerificationTarget.index(of: target.item), goal.doneWhen.indices.contains(index) else {
            return .reject("実機確認の項目 \(target.item) が無い（完了の条件は \(goal.doneWhen.count) 件）")
        }
        let answer = VerificationsFile.Answer(
            id: target.item,
            result: verify.result,
            note: verify.note,
            intent: verify.intent,
            at: context.timestamp
        )
        let saved = try await record(answer, at: path, exists: current != nil, in: context)
        // 読んだ後に、ほかの意図が同じ項目に答えた。次の周で読み直して決める
        guard saved.answer(target.item)?.intent == verify.intent else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// 答えを足す。ファイルが無ければ作る（読んだ後にほかの書き手が作っていたら、次の周で読み直す）
    private func record(
        _ answer: VerificationsFile.Answer,
        at path: String,
        exists: Bool,
        in context: CommanderContext
    ) async throws(CommanderError) -> VerificationsFile {
        let message = "実機確認 \(answer.id) に答える"
        do {
            guard exists else {
                return try await context.files.create(VerificationsFile(answers: [answer]), at: path, message: message).file
            }
            return try await context.files.update(VerificationsFile.self, at: path, message: message) { file in
                guard file.answer(answer.id) == nil else { return false }
                file.answers.append(answer)
                return true
            }.file
        } catch .alreadyExists, .notFound {
            throw .changedWhileProcessing(path)
        } catch {
            throw .files(error)
        }
    }
}
