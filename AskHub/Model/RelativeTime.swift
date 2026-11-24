import Foundation

/// 相対の時刻（例: 8 分前）。端末の言語によらず日本語で出す
enum RelativeTime {
    static func string(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        if abs(now.timeIntervalSince(date)) < 60 {
            return "たった今"
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// 経った時間（例: 3 時間）
    static func duration(since date: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar?.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        let text = formatter.string(from: max(60, now.timeIntervalSince(date))) ?? ""
        // 日本語の書式は「22分」と詰めるので、ほかの文（「16 分前」「残り 3」）と同じく数と単位の間を空ける
        return text.replacingOccurrences(of: #"(\d)(?=[^\d\s])"#, with: "$1 ", options: .regularExpression)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ja_JP")))
    }
}
