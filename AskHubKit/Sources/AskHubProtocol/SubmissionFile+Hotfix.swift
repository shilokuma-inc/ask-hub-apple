import Foundation

// `SubmissionFile` の、配信中の版だけを直す hotfix と、その間に一時停止した進行中のリリース（`docs/renewal/release.md` の「hotfix」）。
// hotfix の release ブランチは配信中の版のタグから作り、版（`MARKETING_VERSION`）を上げる PR を release ブランチに出す。develop には触れない。
// 進行中のリリースは一時停止し（審査中なら取り下げ、App Store Connect の編集できる版は hotfix に回す）、hotfix を配信して
// 進行中の release ブランチに取り込んだら、ビルド・What's New・掲載文の案を作り直して「審査に出す」から再開する

extension SubmissionFile {
    /// hotfix（配信中の版だけを直す）の印
    public struct Hotfix: Codable, Equatable, Sendable {
        /// 直す配信中の版（release ブランチはこの版のタグ `v<版>` から作る）
        public var from: MarketingVersion
        /// 一時停止した進行中のリリースの版。無ければ nil
        public var suspended: MarketingVersion?

        public init(from: MarketingVersion, suspended: MarketingVersion? = nil) {
            self.from = from
            self.suspended = suspended
        }
    }

    /// hotfix の間の一時停止（進行中のリリースに付ける）
    public struct Suspension: Codable, Equatable, Sendable {
        /// 一時停止させた hotfix の版
        public var by: MarketingVersion
        /// hotfix を始めた人の意図（一時停止を確かめたもの）
        public var approval: IntentReference
        public var at: Timestamp
        /// 再開した時刻（hotfix を配信して、この release ブランチに取り込んだ後）。一時停止の間は nil
        public var resumedAt: Timestamp?

        public init(by: MarketingVersion, approval: IntentReference, at: Timestamp, resumedAt: Timestamp? = nil) {
            self.by = by
            self.approval = approval
            self.at = at
            self.resumedAt = resumedAt
        }
    }

    /// hotfix の間、一時停止している（準備を進めず、審査に出せない）
    public var isSuspended: Bool { suspension.map { $0.resumedAt == nil } ?? false }

    /// hotfix の印と一時停止の合わない点
    var hotfixProblems: [String] {
        var problems: [String] = []
        if let hotfix {
            if origin != .askhub { problems.append("hotfix は AskHub で始めた記録だけ") }
            if version <= hotfix.from { problems.append("hotfix の版が、直す配信中の版より大きくない") }
            if hotfix.suspended == version { problems.append("hotfix が自分を一時停止している") }
        }
        if let suspension {
            if origin != .askhub { problems.append("suspension は AskHub で始めた記録だけ") }
            if hotfix != nil { problems.append("hotfix は一時停止しない") }
            if suspension.by == version { problems.append("suspension の by が自分の版") }
            if let resumedAt = suspension.resumedAt, resumedAt < suspension.at { problems.append("suspension の resumedAt が at より前") }
        }
        return problems
    }
}
