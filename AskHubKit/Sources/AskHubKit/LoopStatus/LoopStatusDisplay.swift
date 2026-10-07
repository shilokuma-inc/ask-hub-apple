import Foundation

/// 「ループ」タブの 1 行に出す内容。UI に依存しない部分（文言・記号・停滞の判定・開く URL）をまとめる
public struct LoopStatusDisplay: Sendable, Equatable {
    /// 状態の色の分類。色そのものはアプリが決める
    public enum Tone: Sendable, Equatable {
        /// 動いている
        case active
        /// 人の回答を待っている
        case needsAnswer
        /// 待機・停止中（上限・開始待ち）
        case paused
        /// 異常終了
        case failure
        /// 終わった
        case done
        /// ループが無い・状態が分からない
        case inactive
    }

    /// 進捗のゲージの段階の分類。色そのものはアプリが決める
    ///
    /// しきい値は `ProgressStage.init(fraction:)` の 1 か所にまとめる。境界ちょうどの割合は上の段階に含める
    public enum ProgressStage: Sendable, Equatable, CaseIterable {
        /// 3 分の 1 未満
        case starting
        /// 3 分の 1 以上、3 分の 2 未満
        case halfway
        /// 3 分の 2 以上、すべて終わる前
        case nearlyDone
        /// すべて終わった
        case completed

        /// 0〜1 の割合から段階を決める
        public init(fraction: Double) {
            self = switch fraction {
            case 1...: .completed
            case (2.0 / 3.0)...: .nearlyDone
            case (1.0 / 3.0)...: .halfway
            default: .starting
            }
        }
    }

    /// 「実行中」「担当 PC なし」など。上限で待機中なら再開の時刻も付ける
    public var statusText: String
    /// 状態の SF Symbol
    public var systemImage: String
    public var tone: Tone
    public var epic: String?
    /// 「ゴール元: Discussion #12」
    public var discussionText: String?
    /// 「5 / 12 タスク完了」。保留があれば「5 / 12 タスク完了（うち保留 2）」
    public var progressText: String?
    /// 「5 / 12」（ゲージの横に出す数。読み上げは `progressText`）。保留があれば「5 / 12（保留 2）」
    public var progressCountText: String?
    /// 保留を除いた、終わったタスクの割合（0〜1）。進捗が無ければ `nil`
    public var progressFraction: Double?
    /// 保留で閉じたタスクの割合（0〜1。`progressFraction` の後ろに積む）。
    /// 進捗が無い・保留が 0 件・古いオーケストレーターで保留の数が無いときは `nil`（保留を区別しない表示）
    public var progressDeferredFraction: Double?
    /// 進捗のゲージの段階（保留を除いた割合で決める）。進捗が無ければ `nil`
    public var progressStage: ProgressStage?
    /// ループが最後に動いた時刻（「最後の動き: 3 分前」に使う）
    public var lastActivityAt: Date?
    /// 実行中なのに、`LoopStatusRow.stuckThreshold` より長く動きが無い
    public var isStuck: Bool
    /// 行をタップしたときに開く URL（ゴール元の Discussion、無ければ状態用の Issue）
    public var destination: URL?
}

extension LoopStatusRow {
    /// 実行中のループがこの時間より長く動かなければ、止まっているかもしれないと知らせる
    public static let stuckThreshold: TimeInterval = 30 * 60

    /// 停滞の知らせの文言
    public static let stuckWarning = "長く動きがありません"

    /// 実行中なのに、最後の動きが `stuckThreshold` より古いか。最後の動きの時刻が無ければ判定しない
    public func isStuck(now: Date) -> Bool {
        guard case let .reported(report) = status(now: now), report.state == .running, let lastActivityAt = report.lastActivityAt else {
            return false
        }
        return now.timeIntervalSince(lastActivityAt) > Self.stuckThreshold
    }

    /// 行に出す内容
    public func display(now: Date, calendar: Calendar = .current) -> LoopStatusDisplay {
        let status = status(now: now)
        let report: LoopStatusReport? = if case let .reported(report) = status { report } else { nil }
        return LoopStatusDisplay(
            statusText: Self.statusText(of: status, now: now, calendar: calendar),
            systemImage: Self.systemImage(of: status),
            tone: Self.tone(of: status),
            epic: report?.epic,
            discussionText: report?.discussion.map { "ゴール元: Discussion #\($0)" },
            progressText: report?.progress?.textWithDeferred,
            progressCountText: report?.progress?.countTextWithDeferred,
            progressFraction: report?.progress?.doneFraction,
            progressDeferredFraction: report?.progress.flatMap { $0.deferredCount > 0 ? $0.deferredFraction : nil },
            progressStage: report?.progress.map { LoopStatusDisplay.ProgressStage(fraction: $0.doneFraction) },
            lastActivityAt: report?.lastActivityAt,
            isStuck: isStuck(now: now),
            // 担当 PC がいないときはゴール元を出さないので、開くのも状態用の Issue にそろえる
            destination: (report == nil ? nil : discussionURL) ?? issueURL
        )
    }

    static func statusText(of status: Status, now: Date, calendar: Calendar) -> String {
        switch status {
        case .unassigned:
            return "担当 PC なし"

        case .notReported:
            return "状態なし"

        case let .reported(report):
            if report.state == .usageLimited, let until = report.usageLimitedUntil {
                return "\(report.state.title)（\(UsageLimitedRepository.resumeText(until: until, now: now, calendar: calendar))）"
            }
            return report.state.title
        }
    }

    static func systemImage(of status: Status) -> String {
        switch status {
        case .unassigned:
            return "desktopcomputer"

        case .notReported:
            return "ellipsis.circle"

        case let .reported(report):
            return report.state.systemImage
        }
    }

    static func tone(of status: Status) -> LoopStatusDisplay.Tone {
        switch status {
        case .unassigned, .notReported:
            return .inactive

        case let .reported(report):
            return switch report.state {
            case .running: .active
            case .waitingForAnswer: .needsAnswer
            case .usageLimited, .waitingToStart: .paused
            case .gaveUp: .failure
            case .completed: .done
            case .noLoop, .unknown: .inactive
            }
        }
    }
}

extension LoopStatusReport.Progress {
    /// 終わったタスクの割合。`total` が 0 以下・`completed` が範囲外などの異常値でも 0〜1 に収める
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    /// 保留で閉じたタスクの数。キーが無い（古いオーケストレーター）なら 0。異常値でも 0〜`completed` に収める
    public var deferredCount: Int {
        min(max(deferred ?? 0, 0), max(completed, 0))
    }

    /// 保留を除いた、終わったタスクの割合（0〜1）。保留が無ければ `fraction` と同じ
    public var doneFraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(completed - deferredCount) / Double(total), 0), 1)
    }

    /// 保留で閉じたタスクの割合。`doneFraction` と足して 1 を超えないように収める
    public var deferredFraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(deferredCount) / Double(total), 0), 1 - doneFraction)
    }

    /// 「5 / 12（保留 2）」。保留が無ければ `countText` と同じ
    public var countTextWithDeferred: String {
        deferredCount > 0 ? "\(countText)（保留 \(deferredCount)）" : countText
    }

    /// 「5 / 12 タスク完了（うち保留 2）」。保留が無ければ `text` と同じ
    public var textWithDeferred: String {
        deferredCount > 0 ? "\(text)（うち保留 \(deferredCount)）" : text
    }
}

extension LoopStatusReport.State {
    /// 「ループ」タブに出す SF Symbol
    var systemImage: String {
        switch self {
        case .running: "play.circle.fill"
        case .waitingForAnswer: "questionmark.bubble.fill"
        case .usageLimited: "moon.zzz.fill"
        case .waitingToStart: "pause.circle.fill"
        case .gaveUp: "xmark.octagon.fill"
        case .completed: "checkmark.circle.fill"
        case .noLoop: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }
}
