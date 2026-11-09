import AskHubProtocol
import AskHubStateStore
import Foundation

/// 最終 PR の段取りで司令塔が書く状態のファイル（`epic.json` の最終 PR・`decisions.json` の区分と答え）
extension CommanderContext {
    /// `decisions.json` を書き換える。`change` が false を返したら書かない。書いたかを返す。
    /// ファイルが無ければ、`creating` なら空の一覧に `change` を当てて作り、そうでなければ書かない（仮決めの無い epic の画面の変化）
    @discardableResult
    func updateDecisions(
        of epic: EpicFile,
        message: String,
        creating: Bool = false,
        _ change: (inout DecisionsFile) -> Bool
    ) async throws(CommanderError) -> Bool {
        let path = StatePath.decisions(epic.repo, epic.id)
        var written = false
        do {
            if try await files.read(DecisionsFile.self, at: path) == nil {
                guard creating else { return false }
                var file = DecisionsFile()
                guard change(&file) else { return false }
                do {
                    try await files.create(file, at: path, message: message)
                    return true
                } catch .alreadyExists {
                    // 読んだ後に作られた。下で書き換える
                }
            }
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

    /// 判断の仕分けの結果を写す。仕分けていない仮決めだけを、`visible` に載っていれば見える、無ければ内部の細部にし、
    /// 見えるものには選んだ撮る画面（`scenes`）を書く。仕分け済みの仮決め（人の答えを持つことがある）は変えない。
    /// 画面の変化（`changedScenes`）は、まだ選んでいない（`screens` が nil の）ときだけ写す
    func classifying(visible: [String], scenes: [String: String] = [:], changedScenes: [String]? = nil) -> Self {
        var file = self
        let visible = Set(visible)
        for index in file.items.indices where file.items[index].visible == nil {
            let id = file.items[index].id
            file.items[index].visible = visible.contains(id)
            file.items[index].scene = visible.contains(id) ? scenes[id].flatMap { ScreenshotScenesFile.isSceneID($0) ? $0 : nil } : nil
        }
        if file.screens == nil, let changedScenes {
            var seen = Set<String>()
            let scenes = changedScenes.filter { ScreenshotScenesFile.isSceneID($0) && seen.insert($0).inserted }
            file.screens = scenes.map { ScreenChange(scene: $0) }
        }
        return file
    }

    /// 撮る画面を選んだ見える仮決めか、画面の変化があるか（撮影のジョブを作るか）
    var hasScenes: Bool { items.contains { $0.visible == true && $0.scene != nil } || !(screens ?? []).isEmpty }

    /// 撮影の結果を写す。見える仮決めと画面の変化のうち、結果に載っているものだけを置き換える
    func capturing(_ screenshots: [String: Screenshots], screens changes: [ScreenChange] = []) -> Self {
        var file = self
        for index in file.items.indices where file.items[index].visible == true {
            if let shots = screenshots[file.items[index].id] { file.items[index].screenshots = shots }
        }
        for change in changes {
            guard let index = file.screens?.firstIndex(where: { $0.scene == change.scene }) else { continue }
            file.screens?[index] = change
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
