import Foundation

/// ステータスタブで、リポジトリの見出しの下に並べるループ 1 つ分（同じリポジトリで 2 つ以上のループが回っているとき）
public struct LoopStatusLoopItem: Sendable, Equatable, Identifiable {
    /// このループの状態だけを持つ行。文言・記号・停滞・異常の判定はリポジトリの行と同じものを使う
    public var row: LoopStatusRow
    /// だれが回しているか
    public var mode: LoopMode

    public init(row: LoopStatusRow, mode: LoopMode) {
        self.row = row
        self.mode = mode
    }

    public var id: String {
        row.loopKey
    }

    /// 行に出す内容
    public func display(now: Date, calendar: Calendar = .current) -> LoopStatusDisplay {
        row.display(now: now, calendar: calendar)
    }
}

/// ステータスタブで、ループが 2 つ以上あるリポジトリの見出しに出す、リポジトリ単位の状態（担当 PC・利用上限）
public struct LoopStatusHeading: Sendable, Equatable {
    /// 「ループ 2 つ」「担当 PC なし」「上限で待機中（15:00 に再開）」
    public var statusText: String
    public var systemImage: String
    public var tone: LoopStatusDisplay.Tone
}

extension LoopStatusRow {
    /// ループを見分けるキー（`owner/repo#Discussion の番号` の小文字。番号が無ければリポジトリ名）。異常の数え方に使う
    public var loopKey: String {
        let key = repository.lowercased()
        return report?.discussion.map { "\(key)#\($0)" } ?? key
    }

    /// リポジトリの見出しの下に並べるループ（Discussion の番号の順）。「ループなし」を除いたループが 2 つ以上あるときだけ返し、
    /// 1 つ以下なら空（今までと同じ 1 行で出す）。
    /// 自動ループは同じリポジトリで 1 つしか回らないので、`checkedAt` が最も新しいものだけを並べる（終わったループのコメントが残っていても 2 行にしない）
    /// - Parameter manualLoops: 開いている手動ループ（担当者を出すのに使う。無ければ状態の `runner`）
    public func loopItems(manualLoops: [ManualLoopEpic]) -> [LoopStatusLoopItem] {
        let active = board?.loops.filter { $0.report.state != .noLoop } ?? []
        let automatic = active.filter { $0.report.writer != .manual }.max { $0.report.checkedAt < $1.report.checkedAt }
        let loops = active.filter { $0.report.writer == .manual || $0 == automatic }
        guard loops.count >= 2 else {
            return []
        }
        return loops.map { loop in
            // 担当 PC の判定は 1 行の表示と同じ（担当の印か、そのループの確認時刻）。手動ループは止まると確認時刻を書き直さないので、
            // 確認時刻だけで決めると、回答待ち・開始待ちで止まった手動ループが「担当 PC なし」になってしまう。
            // 実行中のまま書かれなくなった手動ループは、手動ループの節（`ManualLoopItem.isStale`）が知らせる
            let row = LoopStatusRow(repository: repository, report: loop.report, issueURL: issueURL, lastSeen: lastSeen)
            return LoopStatusLoopItem(row: row, mode: Self.mode(of: loop.report, in: repository, manualLoops: manualLoops))
        }
    }

    /// ループの書き手から、だれが回しているかを決める
    static func mode(of report: LoopStatusReport, in repository: String, manualLoops: [ManualLoopEpic]) -> LoopMode {
        guard report.writer == .manual else {
            return .automatic
        }
        let epic = manualLoops.first { epic in
            epic.subject.repository.caseInsensitiveCompare(repository) == .orderedSame && epic.subject.number == report.discussion
        }
        return .manual(assignee: epic?.assignee ?? report.runner)
    }

    /// ループが 2 つ以上あるリポジトリの見出しに出す状態。担当 PC がいなければそれを、上限で待機中ならその時刻を、それ以外はループの数を出す
    public func heading(loopCount: Int, now: Date, calendar: Calendar = .current) -> LoopStatusHeading {
        guard isAssigned(now: now) else {
            return LoopStatusHeading(statusText: "担当 PC なし", systemImage: "desktopcomputer", tone: .inactive)
        }
        if let until = board?.repository?.usageLimitedUntil, until > now {
            let resume = UsageLimitedRepository.resumeText(until: until, now: now, calendar: calendar)
            return LoopStatusHeading(statusText: "上限で待機中（\(resume)）", systemImage: "moon.zzz.fill", tone: .paused)
        }
        return LoopStatusHeading(statusText: "ループ \(loopCount) つ", systemImage: "arrow.triangle.2.circlepath", tone: .inactive)
    }

    /// 異常なループのキー（`loopKey`）。ループを並べるリポジトリはループごとに、それ以外はリポジトリの行で判定する
    public func abnormalLoopKeys(manualLoops: [ManualLoopEpic], now: Date) -> Set<String> {
        let items = loopItems(manualLoops: manualLoops)
        guard !items.isEmpty else {
            return isAbnormal(now: now) ? [loopKey] : []
        }
        return Set(items.filter { $0.row.isAbnormal(now: now) }.map(\.id))
    }
}
