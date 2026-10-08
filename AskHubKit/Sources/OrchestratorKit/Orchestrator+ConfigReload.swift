import Foundation

/// 設定ファイルの読み直し（担当リポジトリの作成・削除の依頼で書き換えた設定や、手で書き換えた設定を再起動せずに反映する）
extension Orchestrator {
    /// 設定を読み直す。読めなければ（書きかけ・JSON の誤りなど）今の設定のまま動き続ける
    func reloadConfig() {
        guard let configStore else {
            return
        }
        let reloaded: OrchestratorConfig
        do {
            reloaded = try configStore.load()
        } catch {
            let reason = "\(error)"
            if reason != lastReloadFailure {
                log("設定を読み直せませんでした。直るまで前の設定のまま動きます: \(reason)")
                lastReloadFailure = reason
            }
            return
        }
        lastReloadFailure = nil
        guard reloaded != config else {
            return
        }
        let before = Set(config.repositories.map { $0.fullName.lowercased() })
        let after = Set(reloaded.repositories.map { $0.fullName.lowercased() })
        let added = reloaded.repositories.filter { !before.contains($0.fullName.lowercased()) }.map(\.fullName)
        let removed = config.repositories.filter { !after.contains($0.fullName.lowercased()) }.map(\.fullName)
        var changes: [String] = []
        if !added.isEmpty {
            changes.append("追加: \(added.joined(separator: ", "))")
        }
        if !removed.isEmpty {
            changes.append("削除: \(removed.joined(separator: ", "))")
        }
        log("設定を読み直しました" + (changes.isEmpty ? "" : "（担当リポジトリの\(changes.joined(separator: " / "))）"))
        config = reloaded
    }
}
