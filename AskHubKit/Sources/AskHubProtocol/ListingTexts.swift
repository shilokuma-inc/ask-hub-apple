import Foundation

/// App Store の 1 つの言語の掲載文（説明文・キーワード・プロモーションテキスト。App Store Connect の `appStoreVersionLocalizations`）。
/// 直す案・人が確かめた直しでは、nil の欄は「変えない」。今の文では、nil の欄は App Store Connect で空
public struct ListingText: Codable, Hashable, Sendable {
    public var locale: String
    public var description: String?
    public var keywords: String?
    public var promotionalText: String?

    public init(locale: String, description: String? = nil, keywords: String? = nil, promotionalText: String? = nil) {
        self.locale = locale
        self.description = description
        self.keywords = keywords
        self.promotionalText = promotionalText
    }

    /// 掲載文の欄
    public enum Field: String, Codable, Sendable, CaseIterable {
        case description
        case keywords
        case promotionalText

        /// 長さの上限（App Store Connect の上限。キーワードはバイト、ほかは文字）
        public var limit: Int {
            switch self {
            case .description: 4_000
            case .keywords: 100
            case .promotionalText: 170
            }
        }

        /// 空にできる（プロモーションテキストだけ。説明文とキーワードは App Store Connect が空を受け付けない）
        public var allowsEmpty: Bool { self == .promotionalText }

        /// `limit` と比べる長さ。キーワードは UTF-8 のバイト（App Store Connect の上限が 100 バイト。多バイト文字の数え方は文書に無いので、
        /// 多めに数える UTF-8 にする）、ほかは Unicode のコードポイント
        public func length(of text: String) -> Int {
            self == .keywords ? text.utf8.count : text.unicodeScalars.count
        }

        /// 上限の言い方（「100 バイト」「4,000 文字」）
        public var limitLabel: String {
            switch self {
            case .description: "4,000 文字"
            case .keywords: "100 バイト"
            case .promotionalText: "170 文字"
            }
        }
    }

    public subscript(field: Field) -> String? {
        get {
            switch field {
            case .description: description
            case .keywords: keywords
            case .promotionalText: promotionalText
            }
        }
        set {
            switch field {
            case .description: description = newValue
            case .keywords: keywords = newValue
            case .promotionalText: promotionalText = newValue
            }
        }
    }

    /// 変える欄が無い
    public var isEmpty: Bool { Field.allCases.allSatisfy { self[$0] == nil } }

    /// 直す案・人が確かめた直しの並びの合わない点（言語の形・重なり・変える欄の無い言語・空の文・長さ）
    public static func problems(of texts: [ListingText], name: String) -> [String] {
        var problems = localeProblems(of: texts, name: name)
        if texts.contains(where: \.isEmpty) { problems.append("\(name) に変える欄の無い言語がある") }
        for field in Field.allCases {
            let values = texts.compactMap { $0[field] }
            if !field.allowsEmpty, values.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                problems.append("\(name) の \(field.rawValue) が空")
            }
            if values.contains(where: { field.length(of: $0) > field.limit }) {
                problems.append("\(name) の \(field.rawValue) が \(field.limitLabel)を超えている")
            }
        }
        return problems
    }

    /// 言語の並びの合わない点（言語の形・重なり・数）。App Store Connect から読んだ今の文は、長さを確かめずにこれだけを確かめる
    public static func localeProblems(of texts: [ListingText], name: String) -> [String] {
        var problems: [String] = []
        if texts.count > LocalizedText.localeLimit { problems.append("\(name) の言語が \(LocalizedText.localeLimit) を超えている") }
        if Set(texts.map(\.locale)).count != texts.count { problems.append("\(name) の言語が重複している") }
        if texts.contains(where: { !LocalizedText.isLocale($0.locale) }) { problems.append("\(name) の locale の形が違う") }
        return problems
    }
}

/// App Review の情報（審査する人に見せるメモとデモアカウント。App Store Connect の `appStoreReviewDetails`）。
/// デモアカウントのパスワードと連絡先は扱わない（パスワードは App Store Connect で人が入れる）。直す案・人が確かめた直しでは、nil の欄は「変えない」
public struct ReviewInformation: Codable, Hashable, Sendable {
    public var notes: String?
    public var demoAccountRequired: Bool?
    public var demoAccountName: String?

    public init(notes: String? = nil, demoAccountRequired: Bool? = nil, demoAccountName: String? = nil) {
        self.notes = notes
        self.demoAccountRequired = demoAccountRequired
        self.demoAccountName = demoAccountName
    }

    /// メモの長さの上限（UTF-8 のバイト。App Store Connect のヘルプが 4,000 バイトと書いている）
    public static let notesLimit = 4_000
    /// デモアカウントの名前の長さの上限（Unicode のコードポイント。文書に上限が無いので、十分に大きくした）
    public static let nameLimit = 255

    /// 変える欄が無い
    public var isEmpty: Bool { notes == nil && demoAccountRequired == nil && demoAccountName == nil }

    /// 合わない点（長さ・改行を含む名前）
    public static func problems(of information: ReviewInformation, name: String) -> [String] {
        var problems: [String] = []
        if let notes = information.notes, notes.utf8.count > notesLimit { problems.append("\(name) の notes が 4,000 バイトを超えている") }
        if let account = information.demoAccountName {
            if account.unicodeScalars.count > nameLimit { problems.append("\(name) の demoAccountName が \(nameLimit) 文字を超えている") }
            if account.contains(where: \.isNewline) { problems.append("\(name) の demoAccountName に改行がある") }
        }
        return problems
    }
}
