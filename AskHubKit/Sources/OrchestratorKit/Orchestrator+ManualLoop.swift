import Foundation

// 手で回す Discussion（manual-loop）の扱い
extension Orchestrator {
    /// `manual-loop` の Discussion。検索に失敗したらログに出して `nil`
    func searchManualLoops() async -> [ManualLoopDiscussion]? {
        do {
            return try await github.manualLoopDiscussions(orgs: config.orgs)
        } catch {
            log("manual-loop の Discussion を検索できませんでした（次のポーリングで検索し直します）: \(error)")
            return nil
        }
    }
}
