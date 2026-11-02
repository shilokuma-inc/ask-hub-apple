import Foundation

/// 全タスクが終わった（`completed`）ループを、最終 PR の段階に応じてステータスタブで出し分ける（Discussion #808 の Q5: 案 A）。
///
/// ループの状態の JSON（`LoopStatusReport.State`）とオーケストレーターは変えず、アプリがマージ待ちの一覧（`epic-final` の PR）と組み合わせて決める。
/// 「完了」と出すのはマージボタンが押せるとき（`EpicPullRequest.canMerge`）だけ。段階の判定は `EpicPullRequest.finalStage` を使い、要対応タブと食い違わないようにする
public enum LoopCompletionStatus: Sendable, Equatable {
    /// マージ待ちの一覧をまだ取れていない（読み込み前・失敗）。今までどおり「完了（最終 PR のマージ待ち）」と出す
    case notLoaded
    /// 一覧に、このループの最終 PR が無い（オーケストレーターがまだ作っていない）
    case finalPullRequestNotFound
    /// このループの最終 PR の段階
    case finalPullRequest(EpicPullRequest.FinalStage)

    /// `repository`（`owner/repo`。大文字小文字を区別しない）の、head が `epic` の最終 PR から決める。
    /// `pullRequests` が `nil` ならマージ待ちの一覧をまだ取れていない
    public init(repository: String, epic: String?, pullRequests: [EpicPullRequest]?) {
        guard let pullRequests else {
            self = .notLoaded
            return
        }
        let finalPullRequest = epic.flatMap { epic in
            pullRequests.first { $0.repository.caseInsensitiveCompare(repository) == .orderedSame && $0.headBranch == epic }
        }
        self = finalPullRequest.map { .finalPullRequest($0.finalStage) } ?? .finalPullRequestNotFound
    }

    /// 「完了」と出すか。マージできるときと、一覧をまだ取れていないとき（今までの表示）
    public var isCompleted: Bool {
        switch self {
        case .notLoaded, .finalPullRequest(.mergeable):
            true

        case .finalPullRequestNotFound, .finalPullRequest:
            false
        }
    }

    /// 異常として目立たせるか（最終 PR の CI 失敗・コンフリクト）
    public var isProblem: Bool {
        if case let .finalPullRequest(stage) = self {
            return stage.isProblem
        }
        return false
    }

    /// ステータスタブに出す文言
    public var statusText: String {
        switch self {
        case .notLoaded, .finalPullRequest(.mergeable):
            LoopStatusReport.State.completed.title

        case .finalPullRequestNotFound:
            "最終 PR の作成待ち"

        case .finalPullRequest(.waitingForChecks):
            "最終 PR の CI 待ち"

        case .finalPullRequest(.checksFailed):
            "最終 PR の CI 失敗"

        case .finalPullRequest(.conflicting):
            "最終 PR がコンフリクト"

        case .finalPullRequest(.waitingForReview):
            "最終 PR のレビュー待ち"

        case .finalPullRequest(.checkingMergeability):
            "最終 PR のマージ可否の確認中"
        }
    }

    /// 状態の SF Symbol
    public var systemImage: String {
        switch self {
        case .notLoaded, .finalPullRequest(.mergeable):
            LoopStatusReport.State.completed.systemImage

        case .finalPullRequest(.checksFailed):
            "xmark.octagon.fill"

        case .finalPullRequest(.conflicting):
            "exclamationmark.triangle.fill"

        case .finalPullRequestNotFound, .finalPullRequest(.waitingForChecks), .finalPullRequest(.waitingForReview),
             .finalPullRequest(.checkingMergeability):
            "hourglass"
        }
    }

    /// 状態の色の分類。CI 失敗は赤（`failure`）、コンフリクトは橙（`paused`）、待ちは動いている（`active`）
    public var tone: LoopStatusDisplay.Tone {
        switch self {
        case .notLoaded, .finalPullRequest(.mergeable):
            .done

        case .finalPullRequest(.checksFailed):
            .failure

        case .finalPullRequest(.conflicting):
            .paused

        case .finalPullRequestNotFound, .finalPullRequest(.waitingForChecks), .finalPullRequest(.waitingForReview),
             .finalPullRequest(.checkingMergeability):
            .active
        }
    }
}

extension LoopStatusRow {
    /// 完了（`completed`）のループなら、最終 PR の段階と組み合わせた状態。完了でない・担当 PC がいない・状態が無いなら `nil`
    public func completionStatus(now: Date, pullRequests: [EpicPullRequest]?) -> LoopCompletionStatus? {
        guard case let .reported(report) = status(now: now), report.state == .completed else {
            return nil
        }
        return LoopCompletionStatus(repository: repository, epic: report.epic, pullRequests: pullRequests)
    }
}

extension LoopStatusDisplay {
    /// 完了のループの文言・記号・色を、最終 PR の段階に合わせて差し替える（`nil` なら何もしない）
    public func applying(_ completion: LoopCompletionStatus?) -> LoopStatusDisplay {
        guard let completion else {
            return self
        }
        var display = self
        display.statusText = completion.statusText
        display.systemImage = completion.systemImage
        display.tone = completion.tone
        return display
    }
}
