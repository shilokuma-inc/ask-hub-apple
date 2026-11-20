import Foundation

// `Submission` の、掲載文と App Review の情報の形（画面用）

extension Submission {
    /// 掲載文の欄（司令塔の `ListingText.Field` と同じ）
    enum ListingField: String, CaseIterable, Hashable, Identifiable {
        case description
        case keywords
        case promotionalText

        var id: String { rawValue }

        var label: String {
            switch self {
            case .description: "説明文"
            case .keywords: "キーワード"
            case .promotionalText: "プロモーションテキスト"
            }
        }

        /// 長さの上限（キーワードは UTF-8 のバイト、ほかは Unicode のコードポイント。App Store Connect の上限）
        var limit: Int {
            switch self {
            case .description: 4_000
            case .keywords: 100
            case .promotionalText: 170
            }
        }

        /// 例: 12 / 100 バイト
        func usage(of text: String) -> String {
            switch self {
            case .keywords: "\(text.utf8.count) / 100 バイト"
            case .description: "\(text.unicodeScalars.count) / 4,000 文字"
            case .promotionalText: "\(text.unicodeScalars.count) / 170 文字"
            }
        }

        /// 送れる長さ
        var rangeLabel: String {
            switch self {
            case .description: "1〜4,000 文字"
            case .keywords: "1〜100 バイト"
            case .promotionalText: "170 文字まで"
            }
        }

        /// 送れる長さか（説明文とキーワードは空にできない）
        func accepts(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return self == .promotionalText }
            let length = self == .keywords ? trimmed.utf8.count : trimmed.unicodeScalars.count
            return length <= limit
        }
    }

    /// 1 つの言語の掲載文。案・直しでは、無い欄は変えない
    struct ListingTexts: Hashable, Identifiable {
        var locale: String
        var values: [ListingField: String] = [:]

        var id: String { locale }

        var localeName: String { Localized(locale: locale, text: "").localeName }

        /// 例: 説明文・キーワード
        var fieldSummary: String {
            ListingField.allCases.filter { values[$0] != nil }.map(\.label).joined(separator: "・")
        }
    }

    /// 掲載文の案
    struct Listing: Hashable {
        /// 配信中の版の掲載文（言語ごと）。空なら初めての版で、案を書かない
        var current: [ListingTexts]
        /// 直す案（変える言語だけ）。空なら「変えない」
        var drafts: [ListingTexts]
        /// 案の理由（変えないなら、その理由）
        var reason: String
    }

    /// App Review の情報（審査する人へのメモとデモアカウント）。パスワードは扱わない。案・直しでは、nil の欄は変えない
    struct ReviewInfo: Hashable {
        var notes: String?
        var demoAccountRequired: Bool?
        var demoAccountName: String?

        /// メモの長さの上限（UTF-8 のバイト。司令塔の `ReviewInformation.notesLimit` と同じ）
        static let notesLimit = 4_000
        /// デモアカウントの名前の長さの上限（Unicode のコードポイント）
        static let nameLimit = 255

        var isEmpty: Bool { notes == nil && demoAccountRequired == nil && demoAccountName == nil }
    }

    /// App Review の情報の案
    struct AppReview: Hashable {
        var current: ReviewInfo
        /// 直す案。nil なら変えない
        var draft: ReviewInfo?
        var reason: String
    }
}
