import Foundation

// 手で回す Discussion（manual-loop）の扱い
extension Orchestrator {
    /// `manual-loop` の Discussion。検索に失敗したらログに出して `nil`
    func searchManualLoops() async -> [ManualLoopDiscussion]? {
        do {
            return try await github.manualLoopDiscussions(orgs: config.orgs)
        } catch {
            log("manual-loop の Discussion を検索できませんでした（ループの起動は次のポーリングで判定します）: \(error)")
            return nil
        }
    }
}
