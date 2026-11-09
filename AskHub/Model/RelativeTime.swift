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
        return formatter.string(from: max(60, now.timeIntervalSince(date))) ?? ""
    }

    static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "ja_JP")))
    }
}
