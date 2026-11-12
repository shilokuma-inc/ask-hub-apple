import AskHubProtocol
import Foundation

// MARK: - 実機確認

extension StateSnapshotBuilder {
    /// 実機で確かめてほしいこと。マージした epic の、ゴールの完了の条件を順に `v1` から並べる（最終 PR の本文と同じ id）。
    ///
    /// TestFlight に上がったかはまだ読まないので、マージしたら確かめられるものとして出す（版は出さない）。
    /// この端末が送って司令塔がまだ処理していない答えは、答えた結果として先に当てる。
    /// 答えの記録を読めなかったときは、どの項目に答えたかが分からないので出さない（同じ項目に二度答えない・依頼を重ねて作らない）
    func verifications(of epicDocuments: StateDocuments.EpicDocuments, pullRequest: Int, index: inout StateIndex) -> [VerificationItem] {
        let file = epicDocuments.epic
        guard file.stage == .merged, let goal = epicDocuments.goal,
              !documents.failures.contains(where: { $0.source == StatePath.verifications(file.repo, file.id) }) else {
            return []
        }
        var answers: [String: VerificationItem.State] = [:]
        for answer in epicDocuments.verifications?.answers ?? [] where answers[answer.id] == nil {
            answers[answer.id] = Self.state(answer.result, note: answer.note)
        }
        let recorded = Set(answers.keys)
        // 司令塔は 1 つの項目への最初の答えだけを受け付けるので、古い順に当てて最初の答えを残す
        for envelope in intentsToOverlay().reversed() where envelope.kind == VerifyIntent.kind {
            guard let intent = try? VerifyIntent(envelope: envelope), intent.target.repo == file.repo, intent.target.epic == file.id,
                  intent.target.goalVersion == goal.version, answers[intent.target.item] == nil,
                  let offset = VerificationTarget.index(of: intent.target.item), goal.doneWhen.indices.contains(offset) else {
                continue
            }
            answers[intent.target.item] = Self.state(intent.result, note: intent.note)
        }
        let items = goal.doneWhen.enumerated().map { offset, text in
            let id = VerificationTarget.itemID(at: offset)
            return VerificationItem(id: id, text: text, steps: "", state: answers[id] ?? .ready(build: nil))
        }
        index.epics[file.id.rawValue]?.verification = StateIndex.VerificationEntry(
            goalVersion: goal.version,
            title: file.title,
            pullRequest: pullRequest,
            items: Dictionary(items.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first }),
            unanswered: Set(items.filter { answers[$0.id] == nil }.map(\.id)),
            problemNotes: answers.compactMapValues { state in
                if case .problem(let note) = state { note } else { nil }
            },
            pendingAnswers: Set(answers.keys).subtracting(recorded)
        )
        return items
    }

    private static func state(_ result: VerifyIntent.Result, note: String) -> VerificationItem.State {
        switch result {
        case .confirmed: .confirmed
        case .problem: .problem(note: note)
        }
    }
}
