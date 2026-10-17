import Foundation

/// ステータスタブで、リポジトリのループをだれが回しているか
public enum LoopMode: Sendable, Equatable {
    /// 担当 PC のオーケストレーターが回している（回す予定）
    case automatic
    /// 手動ループ（`manual-loop` の open な Discussion がある）。担当者が分からなければ `nil`
    case manual(assignee: String?)
    /// epic が動いていない
    case none

    /// 行に出す名前
    public var title: String {
        switch self {
        case .automatic:
            "自動ループ"

        case let .manual(assignee):
            assignee.map { "手動ループ（@\($0)）" } ?? "手動ループ（担当者なし）"

        case .none:
            "ループなし"
        }
    }
}

extension LoopStatusRow {
    /// ループをだれが回しているか。開いている手動ループがあれば手動、無ければ状態から決める
    public func mode(manualLoops: [ManualLoopEpic]) -> LoopMode {
        if let manual = manualLoops.first(where: { $0.subject.repository.caseInsensitiveCompare(repository) == .orderedSame }) {
            return .manual(assignee: manual.assignee)
        }
        switch report?.state {
        case nil, .noLoop, .unknown:
            return .none

        case .running, .waitingForAnswer, .usageLimited, .waitingToStart, .gaveUp, .completed:
            return .automatic
        }
    }

    /// 人が見るべき異常か（ステータスタブのバッジに数える）。
    /// 異常終了・長く動きが無い・進行中の epic があるのに担当 PC がいない
    public func isAbnormal(now: Date) -> Bool {
        if isStuck(now: now) {
            return true
        }
        switch status(now: now) {
        case let .reported(report):
            return report.state == .gaveUp

        case .unassigned:
            // epic が無い（または終わった）リポジトリで担当 PC がいないのは、外しただけかもしれないので数えない
            guard let state = report?.state else {
                return false
            }
            return ![.noLoop, .completed, .unknown].contains(state)

        case .notReported:
            return false
        }
    }
}

/// ステータスタブの「手動ループ」の 1 行
public struct ManualLoopItem: Sendable, Equatable, Identifiable {
    /// 手動ループの状態がこの時間より長く書き直されなければ、止まっているかもしれないと知らせる（10 分ごとに書く決まり）
    public static let staleThreshold: TimeInterval = 30 * 60

    public var epic: ManualLoopEpic
    /// 担当者が書いた状態（`writer` が `manual` で、この Discussion のループのもの）。まだ始めていなければ `nil`
    public var report: LoopStatusReport?
    /// 担当者が自分か
    public var isMine: Bool
    /// 回答待ちだった PR の `needs-answer` がすべて外れ、ループが止まっている（再開してよい）
    public var answersReady: Bool
    /// 実行中のはずなのに、状態が `staleThreshold` より長く書き直されていない
    public var isStale: Bool
    /// epic の最終 PR に信用する author の未処理の指示があり、ループが止まっている（再開して指示を処理させる）。
    /// オーケストレーターは手動ループを再開しないので、担当者に再開を促す
    public var finalInstructionsPending = false

    public var id: String {
        epic.id
    }

    /// 「実行中」「回答待ち」など。まだ始めていなければ「未開始」
    public var statusText: String {
        report?.state.title ?? "未開始"
    }

    /// この Discussion の手動ループの状態。同じリポジトリで複数のループが回るので、本文とループごとのコメント（`board`）から
    /// その Discussion のループを読む。無ければ、ゴール元の番号を書いていない古い形の本文の手動ループ（1 つしか回せなかった頃の形）を使う
    static func manualReport(of discussion: Int, in row: LoopStatusRow) -> LoopStatusReport? {
        if let report = row.board?.loop(discussion: discussion)?.report {
            return report.writer == .manual ? report : nil
        }
        return row.report.flatMap { report in
            report.writer == .manual && (report.discussion == nil || report.discussion == discussion) ? report : nil
        }
    }

    /// 最終 PR への指示を探す手がかり（`ManualLoopFinalInstructionsChecking` に渡す）
    public static func targets(epics: [ManualLoopEpic], rows: [LoopStatusRow]) -> [ManualLoopTarget] {
        epics.map { epic in
            let row = rows.first { $0.repository.caseInsensitiveCompare(epic.subject.repository) == .orderedSame }
            let report = row.flatMap { manualReport(of: epic.subject.number, in: $0) }
            return ManualLoopTarget(repository: epic.subject.repository, discussion: epic.subject.number, epic: report?.epic)
        }
    }

    /// ステータスタブの「手動ループ」に出す行を組み立てる
    /// - Parameters:
    ///   - viewer: トークンの持ち主の login
    ///   - needsAnswer: `needs-answer` が付いている Discussion / PR（`owner/repo#番号` を小文字にしたもの）
    ///   - pendingFinalInstructions: 最終 PR に未処理の指示がある手動ループ（`ManualLoopTarget.key`）
    public static func items(
        epics: [ManualLoopEpic],
        rows: [LoopStatusRow],
        viewer: String?,
        needsAnswer: Set<String>,
        pendingFinalInstructions: Set<String> = [],
        now: Date
    ) -> [Self] {
        epics.map { epic in
            let row = rows.first { $0.repository.caseInsensitiveCompare(epic.subject.repository) == .orderedSame }
            let report = row.flatMap { manualReport(of: epic.subject.number, in: $0) }
            let waiting = report?.waitingPullRequests ?? []
            let answered = waiting.allSatisfy { !needsAnswer.contains("\(epic.subject.repository)#\($0)".lowercased()) }
            let isRunning = report?.state == .running
            return Self(
                epic: epic,
                report: report,
                isMine: viewer.map { viewer in epic.assignee?.caseInsensitiveCompare(viewer) == .orderedSame } ?? false,
                answersReady: report != nil && !isRunning && !waiting.isEmpty && answered,
                isStale: isRunning && report.map { now.timeIntervalSince($0.checkedAt) > staleThreshold } == true,
                finalInstructionsPending: !isRunning && pendingFinalInstructions.contains(
                    ManualLoopTarget.key(repository: epic.subject.repository, discussion: epic.subject.number)
                )
            )
        }
    }
}
