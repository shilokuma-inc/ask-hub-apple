import Foundation

/// 最終 PR のマージの規則（`docs/renewal/flows.md` の「マージの規則」）。司令塔とクライアントで同じ判定を使う
public enum FinalMergeRule {
    /// 人の確認が要る理由
    public enum ManualReason: Equatable, Sendable {
        /// 見える仮決めがある（件数）
        case visibleDecisions(count: Int)
        /// 最終 PR のレビューが見つけた、手動のマージの条件
        case risk(MergeRisk)
    }

    /// 人の確認が要る理由。空なら自動でマージする。仕分ける前の仮決め（`visible` が nil）は、見えるものとして数える
    public static func manualReasons(decisions: DecisionsFile?, mergeRisks: [MergeRisk]) -> [ManualReason] {
        let visible = decisions?.items.filter { $0.visible != false }.count ?? 0
        return (visible > 0 ? [.visibleDecisions(count: visible)] : []) + mergeRisks.map(ManualReason.risk)
    }

    /// マージの承認（`approveMerge`）を受け付けられるか。見える仮決め（仕分ける前のものを含む）のすべてに答えがあるとき
    public static func canApprove(decisions: DecisionsFile?) -> Bool {
        decisions?.items.allSatisfy { $0.visible == false || $0.answer != nil } ?? true
    }
}
