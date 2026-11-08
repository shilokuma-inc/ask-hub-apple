import AskHubProtocol
import AskHubStateStore
import Foundation

/// 最終 PR の段取りで司令塔が書く状態のファイル（`epic.json` の最終 PR・`decisions.json` の区分と答え）
extension CommanderContext {
    /// `decisions.json` を書き換える。`change` が false を返したら書かない。書いたかを返す（ファイルが無ければ書かない）
    @discardableResult
    func updateDecisions(
        of epic: EpicFile,
        message: String,
        _ change: (inout DecisionsFile) -> Bool
    ) async throws(CommanderError) -> Bool {
        let path = StatePath.decisions(epic.repo, epic.id)
        var written = false
        do {
            guard try await files.read(DecisionsFile.self, at: path) != nil else { return false }
            try await files.update(DecisionsFile.self, at: path, message: message) { file in
                written = change(&file)
                return written
            }
        } catch {
            throw .files(error)
        }
        return written
    }

    /// 最終 PR の作成が出した PR を `epic.json` に書く（まだ書いていないときだけ）
    func writeFinalPullRequest(_ pullRequest: Int, to epic: EpicFile) async throws(CommanderError) {
        let now = timestamp
        do {
            try await files.update(EpicFile.self, at: StatePath.epic(epic.repo, epic.id), message: "最終 PR を書く") {
                guard [.finalizing, .reviewing].contains($0.stage), $0.finalPullRequest == nil else { return false }
                $0.finalPullRequest = pullRequest
                $0.updatedAt = now
                return true
            }
        } catch {
            throw .files(error)
        }
    }
}

extension DecisionsFile {
    /// 仕分けていない（`visible` が nil の）仮決めがあるか
    var hasUnclassified: Bool { items.contains { $0.visible == nil } }

    /// 判断の仕分けの結果を写す。仕分けていない仮決めだけを、`visible` に載っていれば見える、無ければ内部の細部にする。
    /// 仕分け済みの仮決め（人の答えを持つことがある）は変えない
    func classifying(visible: [String]) -> Self {
        var file = self
        let visible = Set(visible)
        for index in file.items.indices where file.items[index].visible == nil {
            file.items[index].visible = visible.contains(file.items[index].id)
        }
        return file
    }

    /// 人が頼んだ直しが済んだ: その意図の答え（「別案にする」「直してほしい」）を外し、判断のカードを答え待ちに戻す（直った後を見て答え直してもらう）
    func reopening(answeredBy intent: IntentReference) -> Self {
        var file = self
        for index in file.items.indices where file.items[index].answer?.intent == intent {
            file.items[index].answer = nil
        }
        return file
    }
}
