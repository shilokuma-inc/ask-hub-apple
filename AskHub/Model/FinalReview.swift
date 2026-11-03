import Foundation

/// 最終 PR（epic → develop）の確認。人が決めていない判断のカードと、マージの条件を持つ
struct FinalReview: Hashable {
    var pullRequestNumber: Int
    var additions: Int
    var deletions: Int
    /// いまの head のコミット
    var headCommit: String
    /// 判断を確かめたときの head のコミット。承認の後に push されたら、確かめ直すまでマージしない
    var reviewedHeadCommit: String?
    var checks: FinalChecks
    var mergePolicy: MergePolicy
    var decisions: [DecisionCard]
    /// 内部の細部の仮決め（畳んで並べるだけ）
    var internalDecisions: [String]
    var verifications: [VerificationItem]
    var state: State

    enum MergePolicy: Hashable {
        /// 判断をすべて人がした（View の改修など）
        case automatic
        case manual([ManualReason])
    }

    enum ManualReason: Hashable {
        case delegated(count: Int)
        case visibleDecisions(count: Int)
        case security
        /// ワークフロー・ビルドのスクリプト・署名の設定などの差分
        case sensitivePaths([String])
        /// 自動の修正がテストを弱めた
        case weakenedTests
        case dataMigration

        var label: String {
            switch self {
            case .delegated(let count): "おまかせ \(count) 件"
            case .visibleDecisions(let count): "見える仮決め \(count) 件"
            case .security: "セキュリティの指摘"
            case .sensitivePaths(let paths): "注意が要るファイルの差分（\(paths.joined(separator: "、"))）"
            case .weakenedTests: "自動の修正がテストを弱めた"
            case .dataMigration: "データの削除・移行"
            }
        }
    }

    enum State: Hashable {
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

    enum CIState: Hashable {
        case passed
        case running
        case waitingForRunner(retry: Int, nextAt: Date)
        /// 自動の対処中（区分と何回目か）
        case fixing(FailureCategory, attempt: Int)
        case failed
    }

    /// CI とレビューを本当に通ったか。「マージできます」と出すのはこのときだけ
    var allPassed: Bool {
        ci == .passed && requiredFindings == 0 && securityFindings == 0 && !hasConflict
    }
}

/// 人が決めていない判断（おまかせにした質問と、見える仮決め）のカード
struct DecisionCard: Identifiable, Hashable {
    let id: String
    var kind: Kind
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

    enum Kind: Hashable {
        case delegated(questionID: Question.ID)
        case visible
    }

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
    case image(URL)
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

    /// 人がマージを押せるか（判断をすべて確かめ、CI とレビューを通り、確かめた後の変更が無い）
    var canMerge: Bool {
        state == .reviewable && checks.allPassed && decisions.allSatisfy(\.isConfirmed) && !headChangedAfterReview
    }
}
