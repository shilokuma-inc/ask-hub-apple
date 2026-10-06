import AskHubKit
import Foundation

/// 担当リポジトリ 1 つ分の、ループの状態を決めるための材料。オーケストレーターがポーリングのたびに集める
public struct LoopStatusFacts: Sendable, Equatable {
    public var status: LoopStatus
    /// 制御用 worktree の epic。読めなければ `nil`
    public var snapshot: EpicSnapshot?
    /// Claude の利用上限の解除の時刻（この Mac で待機中なら）
    public var usageLimitedUntil: Date?
    /// 異常終了したループの再開（`StallWatcher`）か、ループの起動（`LaunchTracker`）を諦めた
    public var gaveUp: Bool
    /// このリポジトリの `ready-for-loop` の Discussion のうち、まだ起動していないものの番号
    public var readyDiscussion: Int?
    /// epic の最終 PR が `develop` にマージ済み（制御用 worktree が次の epic に切り替わるまで、完了の goal が残る）
    public var epicMerged: Bool
    /// ループが最後に動いた時刻（state ファイル・ログの更新時刻のうち新しいもの）
    public var lastActivityAt: Date?

    public init(
        status: LoopStatus,
        snapshot: EpicSnapshot?,
        usageLimitedUntil: Date? = nil,
        gaveUp: Bool = false,
        readyDiscussion: Int? = nil,
        epicMerged: Bool = false,
        lastActivityAt: Date? = nil
    ) {
        self.status = status
        self.snapshot = snapshot
        self.usageLimitedUntil = usageLimitedUntil
        self.gaveUp = gaveUp
        self.readyDiscussion = readyDiscussion
        self.epicMerged = epicMerged
        self.lastActivityAt = lastActivityAt
    }
}

/// 担当リポジトリごとのループの状態（`LoopStatusReport`）をまとめる（副作用なし）。
///
/// 複数の状態に当てはまるときは、人がいま気にすべきものを優先する:
/// 上限で待機中 → 実行中 → 異常終了 → epic の進み具合（回答待ち・開始待ち・完了）→ `ready-for-loop` の開始待ち → ループなし
public enum LoopStatusSummary {
    public static func report(for facts: LoopStatusFacts, now: Date) -> LoopStatusReport {
        let epic = facts.epicMerged ? nil : facts.snapshot.flatMap(PreparedEpic.init)
        var report = LoopStatusReport(
            state: state(for: facts, epic: epic, now: now),
            epic: epic?.branch,
            discussion: epic?.discussion,
            progress: epic?.progress,
            lastActivityAt: epic == nil ? nil : facts.lastActivityAt,
            checkedAt: now
        )
        switch report.state {
        case .usageLimited:
            report.usageLimitedUntil = facts.usageLimitedUntil
        case .waitingToStart where epic == nil:
            // 前の epic が無く、`ready-for-loop` の Discussion を待っている
            report.discussion = facts.readyDiscussion
        default:
            break
        }
        return report
    }

    private static func state(for facts: LoopStatusFacts, epic: PreparedEpic?, now: Date) -> LoopStatusReport.State {
        // 上限に達するとループは終わるので、プロセスや state ファイルより先に見る
        if OrchestratorHeartbeat.isUsageLimited(until: facts.usageLimitedUntil, now: now) {
            return .usageLimited
        }
        // 再開に失敗したループは state ファイルが残ったまま `stalled` になる。動いてはいないので実行中としない
        if facts.status.processAlive || (facts.status.stateFileExists == true && !facts.status.stalled) {
            return .running
        }
        if facts.gaveUp {
            return .gaveUp
        }
        if let epic {
            switch epic.phase {
            // 止まったまま（手で止めた・異常終了して再開を待っている）。次の起動・再開を待つ
            case .tasksRemain: return .waitingToStart
            case .waitingForAnswer: return .waitingForAnswer
            // 最終 PR のマージを待つ間は、次の Discussion が `ready-for-loop` でも始まらない
            case .done: return .completed
            }
        }
        return facts.readyDiscussion == nil ? .noLoop : .waitingToStart
    }

    /// goal のチェックボックスの数。タスクが 1 つも無ければ `nil`
    static func progress(in goal: String) -> LoopStatusReport.Progress? {
        let tasks = goal.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- [ ]") || $0.hasPrefix("- [x]") || $0.hasPrefix("- [X]") }
        guard !tasks.isEmpty else {
            return nil
        }
        let completed = tasks.filter { !$0.hasPrefix("- [ ]") }.count
        return .init(completed: completed, total: tasks.count)
    }

    /// 最後に動いた時刻。いずれも無ければ `nil`
    public static func lastActivity(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }
}

/// 準備を終えた `epic/` のブランチと、その goal
private struct PreparedEpic {
    enum Phase {
        /// 回答待ちでない未完了のタスクがある
        case tasksRemain
        /// 未完了のタスクは回答待ちのものだけ
        case waitingForAnswer
        /// 未完了のタスクが無い
        case done
    }

    var branch: String
    var discussion: Int?
    var progress: LoopStatusReport.Progress?
    var phase: Phase

    init?(_ snapshot: EpicSnapshot) {
        guard snapshot.loopPrepared, let branch = snapshot.branch, branch.hasPrefix("epic/"), let goal = snapshot.goal else {
            return nil
        }
        self.branch = branch
        discussion = snapshot.discussion
        progress = LoopStatusSummary.progress(in: goal)
        if EpicCompletion.hasUnfinishedTasks(in: goal) {
            phase = .tasksRemain
        } else if goal.split(whereSeparator: \.isNewline).contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]")
        }) {
            phase = .waitingForAnswer
        } else {
            phase = .done
        }
    }
}
