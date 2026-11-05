import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 質問の一覧の移り変わり（`QuestionFlow.Effect`）を、状態リポジトリに当てる。回答の受け付けと、Claude のジョブの結果で使う
extension CommanderContext {
    /// 司令塔がすることを行う。`origin` はジョブの id を決める元の人の意図。どれも、やり直しても結果が変わらない
    func perform(_ effects: [QuestionFlow.Effect], for epic: EpicFile, origin: IntentReference) async throws(CommanderError) {
        for effect in effects {
            switch effect {
            case let .explain(question, asked):
                let input: [String: JSONValue] = ["question": .string(question), "asked": JSONValue.encoding(asked) ?? .null]
                try await create(claudeJob(.explain, for: epic, origin: asked, seed: question, input: input))
            case let .revise(question, basis):
                let input: [String: JSONValue] = ["question": .string(question), "basis": JSONValue.encoding(basis) ?? .null]
                let dependencies = basis.dependencies.map { "\($0.id):\($0.version):\($0.answer?.nonce.rawValue ?? "-")" }
                let seed = "\(question)/\(basis.version)/\(dependencies.joined(separator: ","))"
                try await create(claudeJob(.reviseQuestion, for: epic, origin: origin, seed: seed, input: input))
            // 取り消すのは、ほかの意図が作ったジョブだけ。この意図が前の周で作ったジョブ（やり直しのとき）は残す
            case let .cancel(question):
                try await cancelJobs(epic.repo, epic: epic.id) { job in
                    [.explain, .reviseQuestion].contains(job.kind)
                        && job.input?["question"]?.stringValue == question
                        && job.origin != origin
                }
            case .reopen:
                // 着手前の確認とゴールの修正をやめ、回答に戻す
                try await cancelJobs(epic.repo, epic: epic.id) { job in
                    [.checkReadiness, .reviseGoal].contains(job.kind) && job.origin != origin
                }
                try await setStage(.asking, of: epic)
            case .checkReadiness:
                try await create(claudeJob(.checkReadiness, for: epic, origin: origin, seed: "", input: [:]))
                try await setStage(.checking, of: epic)
            }
        }
    }

    /// epic の段階を変える。`change` で、ほかの欄も一緒に変えられる
    func setStage(
        _ stage: EpicStage,
        of epic: EpicFile,
        change: @escaping (inout EpicFile) -> Void = { _ in }
    ) async throws(CommanderError) {
        let now = timestamp
        do {
            try await files.update(EpicFile.self, at: StatePath.epic(epic.repo, epic.id), message: "epic を \(stage.rawValue) にする") {
                let before = $0
                $0.stage = stage
                change(&$0)
                guard $0 != before else { return false }
                $0.updatedAt = now
                return true
            }
        } catch {
            throw .files(error)
        }
    }

    /// 質問の一覧を、読んだときのままなら書く。ほかの書き込みで変わっていたら、次の周でやり直す
    func write(
        _ questions: QuestionsFile,
        replacing previous: QuestionsFile,
        of epic: EpicFile,
        message: String
    ) async throws(CommanderError) {
        let path = StatePath.questions(epic.repo, epic.id)
        var changed = false
        do {
            try await files.update(QuestionsFile.self, at: path, message: message) { current in
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
}
