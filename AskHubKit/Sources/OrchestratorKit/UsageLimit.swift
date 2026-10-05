import Foundation

/// Claude の利用上限のメッセージから、解除の時刻を読む（副作用なし）。
///
/// `claude` は上限に達すると、最後に次のような行を出して終わる:
/// - `You've hit your session limit · resets 12pm (Asia/Tokyo)`
/// - `You've hit your weekly limit · resets Oct 7, 9am (Asia/Tokyo)`
/// - `Claude AI usage limit reached|1759456800`（解除の時刻の UNIX 時刻）
public enum UsageLimit {
    /// 出力の末尾から見る行数。上限で終わったなら、メッセージは最後のほうにある
    static let trailingLines = 5
    /// 上限のメッセージはあるが解除の時刻を読めないときに待つ時間
    static let fallbackWait: TimeInterval = 60 * 60
    /// 解除の時刻として受け入れる先の上限（週の上限でも 7 日で解除される）
    static let maximumWait: TimeInterval = 8 * 24 * 60 * 60

    /// - Parameters:
    ///   - output: `claude` の出力（ログの末尾）
    ///   - loggedAt: 出力の時刻（ログの更新時刻）。時刻だけの `resets 12pm` は、これより後の最初のその時刻とみなす
    ///   - timeZone: メッセージにタイムゾーンが無いときに使う
    /// - Returns: 上限で終わっていれば解除の時刻。上限のメッセージが無ければ `nil`
    public static func resetDate(in output: String, loggedAt: Date, timeZone: TimeZone = .current) -> Date? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(trailingLines)
        guard let line = lines.last(where: isLimitMessage) else {
            return nil
        }
        if let match = line.firstMatch(of: /usage limit reached\|(\d{9,})/.ignoresCase()), let epoch = TimeInterval(match.1) {
            let date = Date(timeIntervalSince1970: epoch)
            // ミリ秒などの桁違いの値で待機が長引かないよう、週の上限（7 日）を超える先は読めなかったものとみなす
            return date > loggedAt.addingTimeInterval(maximumWait) ? loggedAt.addingTimeInterval(fallbackWait) : date
        }
        guard let match = line.firstMatch(of: /resets\s+(.+?)(?:\s*\(([^)]+)\))?\s*$/.ignoresCase()) else {
            return loggedAt.addingTimeInterval(fallbackWait)
        }
        let zone = match.2.flatMap { TimeZone(identifier: String($0)) } ?? timeZone
        return resetDate(String(match.1), loggedAt: loggedAt, timeZone: zone) ?? loggedAt.addingTimeInterval(fallbackWait)
    }

    private static func isLimitMessage(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("limit") && (lowered.contains("hit your") || lowered.contains("limit reached"))
    }

    /// `12pm`・`5:30am`・`Oct 7, 9am`・`Oct 7 at 9am` を読む
    private static func resetDate(_ text: String, loggedAt: Date, timeZone: TimeZone) -> Date? {
        let pattern = /^(?:([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/.ignoresCase()
        guard let match = text.firstMatch(of: pattern), var hour = Int(match.3), (1...12).contains(hour) else {
            return nil
        }
        let minute = match.4.flatMap { Int($0) } ?? 0
        hour %= 12
        if match.5.lowercased() == "pm" {
            hour += 12
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents([.year, .month, .day], from: loggedAt)
        components.hour = hour
        components.minute = minute
        if let monthName = match.1, let day = match.2.flatMap({ Int($0) }) {
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = months.firstIndex(of: monthName.lowercased()) else {
                return nil
            }
            components.month = month + 1
            components.day = day
            guard let date = calendar.date(from: components) else {
                return nil
            }
            // 年をまたぐ（12 月のログで `Jan 2`）なら翌年
            return date < loggedAt.addingTimeInterval(-24 * 60 * 60) ? calendar.date(byAdding: .year, value: 1, to: date) : date
        }
        guard let date = calendar.date(from: components) else {
            return nil
        }
        return date > loggedAt ? date : calendar.date(byAdding: .day, value: 1, to: date)
    }
}
