import AskHubKit
import Foundation

/// 担当リポジトリ 1 つ分の、ループの状態を決めるための材料。オーケストレーターがポーリングのたびに集める
public struct LoopStatusFacts: Sendable, Equatable {
    public var status: LoopStatus
    /// 制御用 worktree の epic。読めなければ `nil`
    public var snapshot: EpicSnapshot?
    /// Claude の利用上限の解除の時刻（この Mac で待機中なら）
    public var usageLimitedUntil: Date?
    /// 制御用 worktree の epic の再開（異常終了したループの `StallWatcher`・回答による再開）を諦めた
    public var gaveUp: Bool
    /// このリポジトリの `ready-for-loop` の Discussion のうち、制御用 worktree が準備を終えていないものの番号
    /// （手動ループ・信用しない author のものは除く）。オーケストレーターを起動してからまだ一度も取得できていなければ `nil`
    public var readyDiscussions: [Int]?
    /// 起動して、ループの開始を待っている Discussion の番号（`LaunchTracker`）
    public var startingDiscussions: [Int]
    /// 起動して、ループの開始を確かめた Discussion の番号（`LaunchTracker`。ラベルを外し終えて検索結果から消えるまで）
    public var startedDiscussions: [Int]
    /// 起動を諦めた Discussion の番号（`LaunchTracker`）
    public var givenUpDiscussions: [Int]
    /// ask に回答が付き、ループの再開を待っている（goal の `※回答待ち` はループが再開して外すまで残る）
    public var hasAnsweredQuestions: Bool
    /// epic の最終 PR が `develop` にマージ済み（制御用 worktree が次の epic に切り替わるまで、完了の goal が残る）
    public var epicMerged: Bool
    /// ループが最後に動いた時刻（state ファイル・ログの更新時刻のうち新しいもの）
    public var lastActivityAt: Date?
    /// ループのスロットのビルドの情報。準備を終えた epic のループ（スロットを使うループ）に載せる
    public var builds: LoopStatusBuilds?

    public init(
        status: LoopStatus,
        snapshot: EpicSnapshot?,
        usageLimitedUntil: Date? = nil,
        gaveUp: Bool = false,
        readyDiscussions: [Int]? = [],
        startingDiscussions: [Int] = [],
        startedDiscussions: [Int] = [],
        givenUpDiscussions: [Int] = [],
        hasAnsweredQuestions: Bool = false,
        epicMerged: Bool = false,
        lastActivityAt: Date? = nil,
        builds: LoopStatusBuilds? = nil
    ) {
        self.status = status
        self.snapshot = snapshot
        self.usageLimitedUntil = usageLimitedUntil
        self.gaveUp = gaveUp
        self.readyDiscussions = readyDiscussions
        self.startingDiscussions = startingDiscussions
        self.startedDiscussions = startedDiscussions
        self.givenUpDiscussions = givenUpDiscussions
        self.hasAnsweredQuestions = hasAnsweredQuestions
        self.epicMerged = epicMerged
        self.lastActivityAt = lastActivityAt
        self.builds = builds
    }
}

/// 担当リポジトリの、この PC の自動ループの状態。ループ（Discussion）ごとに 1 つ
public struct AutomaticLoops: Sendable, Equatable {
    /// Discussion ごとの状態（番号の小さい順。どれも `discussion` を持つ）
    public var reports: [LoopStatusReport]
    /// どの Discussion のものか分からないループがある（手で始めた epic・起動の記録の無いループが動いている・
    /// `ready-for-loop` の一覧をまだ取得していない）。その間は、ここに無い Discussion のループが終わったのか分からない
    public var includesUnknownLoop: Bool

    public init(reports: [LoopStatusReport], includesUnknownLoop: Bool = false) {
        self.reports = reports
        self.includesUnknownLoop = includesUnknownLoop
    }
}

/// 担当リポジトリの自動ループの状態（`LoopStatusReport`）を、ループ（Discussion）ごとにまとめる（副作用なし）。
///
/// 自動ループが同時に動くのはリポジトリに 1 つだが、状態は Discussion ごとに持つ（Discussion #425 の Q1 と、PR #437 の担当者の判断）。
/// 制御用 worktree に準備を終えた epic（例: 完了して最終 PR のマージ待ちの #12）が残ったまま、別の Discussion（#30）を起動した・起動を諦めた・
/// 待っているときは、#12 には epic の状態を、#30 には起動の状態を出す:
///
/// - 準備を終えた epic: 上限で待機中 → 実行中 → 異常終了 → epic の進み具合（回答待ち・開始待ち・完了）。
///   制御用 worktree のプロセス・state ファイルは、epic と別の Discussion を起動して開始を待っていればそのループのものとし、epic の実行中にしない
/// - 起動した Discussion: 上限で待機中 → 実行中（ループの開始を待っている・確かめた）・異常終了（起動を諦めた）。
///   開始を確かめた Discussion は、制御用 worktree が別の epic に替わっていれば（ラベルを外せないまま残った記録）、ループは終わったものとして書かない
/// - `ready-for-loop` の Discussion: 上限で待機中 → 開始待ち
public enum LoopStatusSummary {
    public static func loops(for facts: LoopStatusFacts, now: Date) -> AutomaticLoops {
        let epic = facts.epicMerged ? nil : facts.snapshot.flatMap(PreparedEpic.init)
        // 上限に達するとループは終わるので、プロセスや state ファイルより先に見る（この Mac のすべての自動ループが待つ）
        let limitedUntil = OrchestratorHeartbeat.isUsageLimited(until: facts.usageLimitedUntil, now: now) ? facts.usageLimitedUntil : nil
        // 再開に失敗したループは state ファイルが残ったまま `stalled` になる。動いてはいないので実行中としない
        let active = facts.status.processAlive || (facts.status.stateFileExists == true && !facts.status.stalled)
        var reports: [Int: LoopStatusReport] = [:]
        var unknown = facts.readyDiscussions == nil
        if let epic {
            if let report = epicReport(epic, active: active, limitedUntil: limitedUntil, facts: facts, now: now),
               let number = report.discussion {
                reports[number] = report
            } else {
                // 手で始めた epic（ゴール元の記録が無い）は、どの Discussion のループか分からない
                unknown = true
            }
        }
        // 開始を確かめた Discussion のループは、制御用 worktree の epic のもの。準備を終えた epic が別の Discussion のもの・
        // 別の Discussion を起動して開始を待っているときは、制御用 worktree は替わっているので、そのループは終わっている
        let confirmed = facts.startedDiscussions.filter { number in
            (epic.map { $0.discussion == number } ?? true) && !facts.startingDiscussions.contains { $0 != number }
        }
        if epic == nil && active && facts.startingDiscussions.isEmpty && confirmed.isEmpty {
            // 準備を終えた epic も起動の記録も無いのに動いている（手で始めたループなど）
            unknown = true
        }
        let started = (facts.startingDiscussions + confirmed).map { ($0, LoopStatusReport.State.running) }
        let givenUp = facts.givenUpDiscussions.map { ($0, LoopStatusReport.State.gaveUp) }
        let waiting = (facts.readyDiscussions ?? []).map { ($0, LoopStatusReport.State.waitingToStart) }
        // 準備を終えた epic と同じ Discussion は epic の状態を、起動を追っている Discussion は ready の開始待ちより起動の状態を使う
        for (number, state) in started + givenUp + waiting where reports[number] == nil {
            reports[number] = LoopStatusReport(
                state: limitedUntil == nil ? state : .usageLimited, discussion: number, usageLimitedUntil: limitedUntil, checkedAt: now
            )
        }
        return AutomaticLoops(reports: reports.keys.sorted().compactMap { reports[$0] }, includesUnknownLoop: unknown)
    }

    /// 準備を終えた epic のループ。制御用 worktree のプロセス・state ファイルは、epic と別の Discussion を起動して開始を待っていればそのループのもの
    private static func epicReport(
        _ epic: PreparedEpic, active: Bool, limitedUntil: Date?, facts: LoopStatusFacts, now: Date
    ) -> LoopStatusReport? {
        guard let number = epic.discussion else {
            return nil
        }
        let state: LoopStatusReport.State
        if limitedUntil != nil {
            state = .usageLimited
        } else if active && !facts.startingDiscussions.contains(where: { $0 != number }) {
            state = .running
        } else if facts.gaveUp || facts.givenUpDiscussions.contains(number) {
            state = .gaveUp
        } else {
            switch epic.phase {
            // 止まったまま（手で止めた・異常終了して再開を待っている）。次の起動・再開を待つ
            case .tasksRemain: state = .waitingToStart
            // 回答が付いていれば、もう人を待っていない（再開に失敗して止まっている間も含む）
            case .waitingForAnswer: state = facts.hasAnsweredQuestions ? .waitingToStart : .waitingForAnswer
            // 最終 PR のマージを待っている。次の Discussion を起動しても、この epic の状態として残す
            case .done: state = .completed
            }
        }
        return LoopStatusReport(
            state: state,
            epic: epic.branch,
            discussion: number,
            progress: epic.progress,
            lastActivityAt: facts.lastActivityAt,
            usageLimitedUntil: limitedUntil,
            checkedAt: now,
            builds: facts.builds
        )
    }

    /// goal で保留として閉じたタスクの目印（playbook の「詰まったときの扱い」の `- [x] … ※保留（YYYY-MM-DD）: …`）
    static let deferredMark = "※保留"

    /// goal のチェックボックスの数。タスクが 1 つも無ければ `nil`。
    /// 保留で閉じたタスクは `completed` に含めたまま（古いアプリとの互換）、`deferred` にも数える
    static func progress(in goal: String) -> LoopStatusReport.Progress? {
        let tasks = goal.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- [ ]") || $0.hasPrefix("- [x]") || $0.hasPrefix("- [X]") }
        guard !tasks.isEmpty else {
            return nil
        }
        let completed = tasks.filter { !$0.hasPrefix("- [ ]") }
        let deferred = completed.filter { $0.contains(deferredMark) }.count
        return .init(completed: completed.count, total: tasks.count, deferred: deferred)
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
