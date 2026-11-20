import Foundation

/// 人が値を確かめて、司令塔に書かせる決まった値（`applyAppStoreSettings` の payload と同じ形）。書く欄だけを持つ
public struct AppStoreSettings: Codable, Hashable, Sendable {
    /// 価格。今は無料（`free`）だけ
    public enum Price: String, Codable, Sendable, CaseIterable {
        case free
    }

    /// 配信の地域。今はすべての地域（`allTerritories`。新しい地域にも配信する）だけ
    public enum Availability: String, Codable, Sendable, CaseIterable {
        case allTerritories
    }

    /// App Review の連絡先。今は同じ鍵のほかのアプリ（配信中か審査に出した版）の連絡先を写す（`copyFromOtherApp`）だけ。
    /// 連絡先は個人の情報なので、値は意図にも記録にも持たない（GitHub の Secrets は司令塔から読めないので、App Store Connect の中で写す）
    public enum ReviewContact: String, Codable, Sendable, CaseIterable {
        case copyFromOtherApp
    }

    public var contentRights: ContentRightsDeclaration?
    /// 主なカテゴリ（App Store Connect の `appCategories` の id。`PRODUCTIVITY` など）
    public var primaryCategory: String?
    /// 主なカテゴリのサブカテゴリ（ゲームの `GAMES_PUZZLE` など）。`primaryCategory` があるときだけ
    public var primarySubcategory: String?
    /// プライバシーポリシーの URL（https）。App Store Connect のすべての言語のうち、まだ書かれていないものに書く
    public var privacyPolicyUrl: String?
    public var price: Price?
    public var availability: Availability?
    /// 初めての版のサポート URL（https）。版の枠の言語のうち、まだ書かれていないものに書く
    public var supportUrl: String?
    /// 初めての版のマーケティング URL（https。任意）。`supportUrl` と一緒に送り、版の枠の言語のうち、まだ書かれていないものに書く
    public var marketingUrl: String?
    /// 初めての版の著作権表示（`2026 Shilokuma Inc.` のように、権利を得た年と持ち主）。版の枠のうち、まだ書かれていないものに書く
    public var copyright: String?
    /// 初めての版の App Review の連絡先。版の枠のうち、まだ入れていない欄に写す
    public var reviewContact: ReviewContact?

    public init(
        contentRights: ContentRightsDeclaration? = nil,
        primaryCategory: String? = nil,
        primarySubcategory: String? = nil,
        privacyPolicyUrl: String? = nil,
        price: Price? = nil,
        availability: Availability? = nil,
        supportUrl: String? = nil,
        marketingUrl: String? = nil,
        copyright: String? = nil,
        reviewContact: ReviewContact? = nil
    ) {
        self.contentRights = contentRights
        self.primaryCategory = primaryCategory
        self.primarySubcategory = primarySubcategory
        self.privacyPolicyUrl = privacyPolicyUrl
        self.price = price
        self.availability = availability
        self.supportUrl = supportUrl
        self.marketingUrl = marketingUrl
        self.copyright = copyright
        self.reviewContact = reviewContact
    }

    /// URL（プライバシーポリシー・サポート・マーケティング）の長さの上限
    public static let urlLimit = 512

    /// 著作権表示の長さの上限
    public static let copyrightLimit = 200

    /// 書く項目（チェックリストの項目）。マーケティング URL は任意なので項目を持たず、サポート URL と一緒に書く
    public var items: [AppStoreSetupFile.ItemKind] {
        var items: [AppStoreSetupFile.ItemKind] = []
        if contentRights != nil { items.append(.contentRights) }
        if primaryCategory != nil { items.append(.category) }
        if privacyPolicyUrl != nil { items.append(.privacyPolicy) }
        if price != nil { items.append(.price) }
        if availability != nil { items.append(.availability) }
        if supportUrl != nil { items.append(.supportUrl) }
        if copyright != nil { items.append(.copyright) }
        if reviewContact != nil { items.append(.reviewContact) }
        return items
    }

    /// 合わない点（何も書かない・カテゴリの形・URL の形・著作権表示の形）
    public var problems: [String] {
        var problems: [String] = []
        if items.isEmpty { problems.append("書く値が 1 つも無い") }
        if let primaryCategory, !Self.isCategory(primaryCategory) { problems.append("primaryCategory の形が違う") }
        if let primarySubcategory {
            if !Self.isCategory(primarySubcategory) { problems.append("primarySubcategory の形が違う") }
            if primaryCategory == nil { problems.append("primarySubcategory は primaryCategory と一緒に送る") }
        }
        if let privacyPolicyUrl, !Self.isURL(privacyPolicyUrl) { problems.append("privacyPolicyUrl が https の URL でない") }
        if let supportUrl, !Self.isURL(supportUrl) { problems.append("supportUrl が https の URL でない") }
        if let marketingUrl {
            if !Self.isURL(marketingUrl) { problems.append("marketingUrl が https の URL でない") }
            if supportUrl == nil { problems.append("marketingUrl は supportUrl と一緒に送る") }
        }
        if let copyright, !Self.isCopyright(copyright) {
            problems.append("copyright が空か、改行を含むか、\(Self.copyrightLimit) 文字を超えている")
        }
        return problems
    }

    /// 著作権表示の形（前後に空白が無く、改行・制御文字を含まず、`copyrightLimit` 文字まで）
    public static func isCopyright(_ text: String) -> Bool {
        let forbidden = CharacterSet.newlines.union(.controlCharacters)
        return (1...copyrightLimit).contains(text.unicodeScalars.count)
            && text.trimmingCharacters(in: .whitespaces) == text
            && !text.unicodeScalars.contains(where: forbidden.contains)
    }

    /// App Store Connect のカテゴリの id の形（英大文字・数字・`_`）
    public static func isCategory(_ text: String) -> Bool {
        guard let first = text.utf8.first, (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) else { return false }
        return text.utf8.count <= 64 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }

    /// https の URL（空白・制御文字を含まず、ホストがある）
    public static func isURL(_ text: String) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard text.unicodeScalars.count <= urlLimit, text.hasPrefix("https://"),
              !text.unicodeScalars.contains(where: forbidden.contains),
              let url = URL(string: text), url.scheme == "https", let host = url.host(), !host.isEmpty else {
            return false
        }
        return true
    }
}
