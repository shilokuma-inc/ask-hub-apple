import Foundation

// `ReleaseFile` の、配信中の版のプロモーションテキスト（審査に出さずに変えられる。`docs/renewal/release.md` の「掲載文」）

extension ReleaseFile {
    /// 配信中の版のプロモーションテキスト。司令塔が配信の見回り（30 分ごと）で読み、人が「反映する」を押したら App Store Connect に書く
    public struct PromotionalText: Codable, Equatable, Sendable {
        /// 言語ごとの今の文（App Store Connect で読んだもの。空の言語は空の文字列）
        public var current: [LocalizedText]
        /// 今の文を読んだ時刻（読んだ文が変わったときだけ書き直す）
        public var readAt: Timestamp
        /// 人が「反映する」を押した中身（`updatePromotionalText`）。新しく押したら置き換える
        public var request: PromotionalTextRequest?

        public init(current: [LocalizedText], readAt: Timestamp, request: PromotionalTextRequest? = nil) {
            self.current = current
            self.readAt = readAt
            self.request = request
        }
    }

    /// 人が直したプロモーションテキスト。司令塔が書き終えたら `doneAt`、App Store Connect が断ったら `failure` が付く（断られたら書き直さない）
    public struct PromotionalTextRequest: Codable, Equatable, Sendable {
        public var approval: IntentReference
        public var at: Timestamp
        /// 書く文（変える言語だけ。空の文字列は空にする）
        public var texts: [LocalizedText]
        public var doneAt: Timestamp?
        /// App Store Connect が断った理由（人が確かめる）
        public var failure: String?

        public init(approval: IntentReference, at: Timestamp, texts: [LocalizedText], doneAt: Timestamp? = nil, failure: String? = nil) {
            self.approval = approval
            self.at = at
            self.texts = texts
            self.doneAt = doneAt
            self.failure = failure
        }

        /// 司令塔がまだ書いていない（書き終えていない・断られていない）
        public var isPending: Bool { doneAt == nil && failure == nil }
    }

    /// プロモーションテキストの並びの合わない点（言語の形・重なり・長さ。空の文字列は「空」として許す）
    public static func promotionalTextProblems(of texts: [LocalizedText], name: String) -> [String] {
        var problems: [String] = []
        if texts.count > LocalizedText.localeLimit { problems.append("\(name) の言語が \(LocalizedText.localeLimit) を超えている") }
        if Set(texts.map(\.locale)).count != texts.count { problems.append("\(name) の言語が重複している") }
        if texts.contains(where: { !LocalizedText.isLocale($0.locale) }) { problems.append("\(name) の locale の形が違う") }
        let field = ListingText.Field.promotionalText
        if texts.contains(where: { field.length(of: $0.text) > field.limit }) {
            problems.append("\(name) の text が \(field.limitLabel)を超えている")
        }
        return problems
    }

    /// プロモーションテキストの欄の合わない点
    var promotionalTextViolations: [String] {
        guard let promotionalText else { return [] }
        var violations = Self.promotionalTextProblems(of: promotionalText.current, name: "promotionalText の current")
        if let request = promotionalText.request {
            violations += Self.promotionalTextProblems(of: request.texts, name: "promotionalText の request の texts")
            if request.texts.isEmpty { violations.append("promotionalText の request の texts が空") }
            if request.doneAt != nil && request.failure != nil {
                violations.append("promotionalText の request は、doneAt と failure を両方は持たない")
            }
            if request.failure?.isEmpty == true { violations.append("promotionalText の request の failure が空") }
        }
        return violations
    }
}
