import Foundation

/// 最終 PR（epic → develop）の確認。人が決めていない判断のカードと、マージの条件を持つ
struct FinalReview: Hashable {
    var pullRequestNumber: Int
    /// 追加・削除の行数。状態リポジトリには無い（対象のリポジトリの API は呼ばない）ので、分からなければ nil
    var additions: Int?
    var deletions: Int?
    /// いまの head のコミット。分からなければ（最終 PR のレビューのジョブが無い・マージした epic のジョブを読まない）nil
    var headCommit: String?
    /// 判断を確かめたときの head のコミット。承認の後に push されたら、確かめ直すまでマージしない
    var reviewedHeadCommit: String?
    var checks: FinalChecks
    var mergePolicy: MergePolicy
    var decisions: [DecisionCard]
    /// 内部の細部の仮決め（畳んで並べるだけ）
    var internalDecisions: [String]
    var verifications: [VerificationItem]
    var state: State
    /// マージの承認を司令塔が受け付けるか（`FinalMergeRule.canApprove`。見える仮決めのすべてに答えがある）
    var acceptsApproval = true

    enum MergePolicy: Hashable {
        /// 判断をすべて人がした（View の改修など）
        case automatic
        case manual([ManualReason])
    }

    enum ManualReason: Hashable {
        case visibleDecisions(count: Int)
        case security
        /// ワークフロー・ビルドのスクリプト・署名の設定などの差分
        case sensitivePaths([String])
        /// 自動の修正がテストを弱めた
        case weakenedTests
        case dataMigration
        /// 通ったレビューが、マージの規則の材料（セキュリティ・テストを弱めたか など）を返さなかった
        case risksUnknown
        /// 判断の一覧を読めていない（答えていない判断があるかもしれない）
        case decisionsUnreadable

        var label: String {
            switch self {
            case .visibleDecisions(let count): "見える仮決め \(count) 件"
            case .security: "セキュリティの指摘"
            case .sensitivePaths(let paths): "注意が要るファイルの差分（\(paths.joined(separator: "、"))）"
            case .weakenedTests: "自動の修正がテストを弱めた"
            case .dataMigration: "データの削除・移行"
            case .risksUnknown: "レビューがマージの規則の材料を返さなかった"
            case .decisionsUnreadable: "判断の一覧を読めていない"
            }
        }
    }

    enum State: Hashable {
        /// 機械が最終 PR を確かめている・直している（人の番ではない。判断の確認とマージはまだできない）
        case checking
        case reviewable
        case merging
        case merged(at: Date, automatic: Bool)
    }
}

/// CI とレビューの要約
struct FinalChecks: Hashable {
    var ci: CIState
    var requiredFindings: Int
    var securityFindings: Int
    var hasConflict: Bool
    /// 最後のレビューが返した直すこと（落ちたチェックとログの抜粋・必須の指摘）
    var findings: String?

    enum CIState: Hashable {
        case passed
        case running
        /// CI とレビューの結果を待って、確かめている
        case reviewing
        case waitingForRunner(retry: Int, nextAt: Date)
        /// 自動の対処中（区分と何回目か）
        case fixing(FailureCategory, attempt: Int)
        /// 人が頼んだ直し（判断のカードの「直してほしい」「別案にする」・最終 PR への指示）をしている
        case fixingByRequest
        case failed
    }

    /// CI とレビューを本当に通ったか。「マージできます」と出すのはこのときだけ
    var allPassed: Bool {
        ci == .passed && requiredFindings == 0 && securityFindings == 0 && !hasConflict
    }
}

/// 人が決めていない判断のカード。実装の中でループが仮に決めた、見た目や挙動に関わること（見える仮決め）。
/// 質問への回答はいつも人がするので、ここに載るのはループの仮決めだけ
struct DecisionCard: Identifiable, Hashable {
    let id: String
    /// 何を決めたか
    var title: String
    var reason: String
    /// ゴールのどの項目から来たか
    var goalSource: String?
    var alternatives: [String]
    var before: Screenshot?
    var after: Screenshot?
    var response: Response
    /// 慎重に確かめてほしい理由（セキュリティなど）。あれば札を警告ふうに出す
    var caution: Caution?
    /// スクショに添えるわけ（例: このリポジトリには撮影の設定が無い・Before なし）。スクショがあっても出す
    var screenshotNote: String?

    enum Response: Hashable {
        case pending
        case accepted
        /// 「別案にする」「直してほしい」を受けて、ループが直している
        case fixing(request: String)
        /// 直したのでもう一度確かめてほしい
        case refreshed(note: String)
    }

    var isConfirmed: Bool { response == .accepted }

    var needsReview: Bool {
        switch response {
        case .pending, .refreshed:
            return true

        case .accepted, .fixing:
            return false
        }
    }
}

/// 判断のカードのスクショ（撮影にはデモモードのデータを使う）
enum Screenshot: Hashable {
    /// ワーカーが撮って状態リポジトリに置いた画像（epic の `screenshots/` の下のパス）。`ClientStore.screenshot(at:)` で読む
    case stored(String)
    /// デモのデータ用。アプリの中で描く
    case demo(DemoScreen)
}

/// 実機で確かめてほしいこと。マージは止めない
struct VerificationItem: Identifiable, Hashable {
    let id: String
    var text: String
    var steps: String
    var state: State

    enum State: Hashable {
        /// TestFlight に上がるのを待っている
        case waitingForBuild
        case ready(build: String)
        case confirmed
        case problem(note: String)
    }

    var isReady: Bool {
        if case .ready = state {
            return true
        }
        return false
    }
}

extension FinalReview {
    var reviewedCount: Int { decisions.filter(\.isConfirmed).count }

    var pendingDecisions: [DecisionCard] { decisions.filter(\.needsReview) }

    var isFixing: Bool {
        decisions.contains {
            if case .fixing = $0.response {
                return true
            }
            return false
        }
    }

    /// 確かめた後に変更が push されたか
    var headChangedAfterReview: Bool {
        guard let reviewedHeadCommit else {
            return false
        }
        return reviewedHeadCommit != headCommit
    }

    /// 人がマージを押せるか（判断をすべて確かめ、CI とレビューを通り、確かめた後の変更が無く、承認を結びつける head が分かる）
    var canMerge: Bool {
        state == .reviewable && checks.allPassed && decisions.allSatisfy(\.isConfirmed) && acceptsApproval
            && !headChangedAfterReview && headCommit != nil
    }

    /// 追加・削除の行数（例: +1,204 −310）。分からなければ nil
    var lineChanges: String? {
        guard let additions, let deletions else {
            return nil
        }
        return "+\(additions) −\(deletions)"
    }
}
