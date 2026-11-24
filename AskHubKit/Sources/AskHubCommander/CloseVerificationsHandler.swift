import AskHubProtocol
import AskHubStateStore
import Foundation

/// 実機確認をまとめて答える意図（`closeVerifications`）を受け付け、まだ答えていない項目すべてを `verifications.json` に記録する
/// （`docs/renewal/flows.md` の「実機で確かめてほしいこと」の「溜まった確認を減らす」）。
///
/// 「まとめて確認した」は `confirmed`、「確かめずに閉じる」は `skipped` として、同じ意図・同じ時刻で項目の順に足す。
/// もう答えた項目は答え直さない。答えていない項目が無ければ、何も書かずに受け付ける
public struct CloseVerificationsHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let close: CloseVerificationsIntent
        do {
            close = try CloseVerificationsIntent(envelope: envelope)
        } catch {
            return .reject("実機確認のまとめての答えの形が違う（\(error.detail)）")
        }
        let target = close.target
        let path = StatePath.verifications(target.repo, target.epic)
        let current = try await context.read(VerificationsFile.self, at: path)
        // 前の周で記録した（やり直し）なら済んでいる
        if current?.answers.contains(where: { $0.intent == close.intent }) == true {
            return .accept
        }
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(target.repo, target.epic)) else {
            return .reject("epic が無い")
        }
        guard epic.stage == .merged else { return .reject("最終 PR をマージした epic でない（今は \(epic.stage.rawValue)）") }
        guard let goal = try await context.read(GoalFile.self, at: StatePath.goal(target.repo, target.epic)) else {
            return .reject("ゴールが無い")
        }
        guard goal.version == target.version else { return .reject("ゴールの版が違う（今の版は \(goal.version)）") }
        let items = goal.doneWhen.indices.map(VerificationTarget.itemID(at:))
        let answers = items.filter { current?.answer($0) == nil }.map { item in
            VerificationsFile.Answer(id: item, result: close.result.answer, note: close.note, intent: close.intent, at: context.timestamp)
        }
        guard !answers.isEmpty else { return .accept }
        let saved = try await record(answers, at: path, exists: current != nil, in: context)
        // 読んだ後に、ほかの意図が答えた項目があっても、すべての項目に答えが揃っていれば済んでいる。揃っていなければ次の周で読み直す
        guard items.allSatisfy({ saved.answer($0) != nil }) else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// まだ答えていない項目の答えを足す。ファイルが無ければ作る（読んだ後にほかの書き手が作っていたら、次の周で読み直す）
    private func record(
        _ answers: [VerificationsFile.Answer],
        at path: String,
        exists: Bool,
        in context: CommanderContext
    ) async throws(CommanderError) -> VerificationsFile {
        let message = "実機確認の残り \(answers.count) 件にまとめて答える"
        do {
            guard exists else {
                return try await context.files.create(VerificationsFile(answers: answers), at: path, message: message).file
            }
            return try await context.files.update(VerificationsFile.self, at: path, message: message) { file in
                let remaining = answers.filter { file.answer($0.id) == nil }
                guard !remaining.isEmpty else { return false }
                file.answers += remaining
                return true
            }.file
        } catch .alreadyExists, .notFound {
            throw .changedWhileProcessing(path)
        } catch {
            throw .files(error)
        }
    }
}
