import Foundation

/// `repos/<owner>/<repo>/app-store.json`（新しいアプリを App Store に載せる準備）。司令塔だけが書く。
///
/// 司令塔が App Store Connect にアプリを見つけられない・配信中の版が無いリポジトリに作り、チェックリストの項目が終わったかを API で確かめて書く。
/// API で確かめられない項目（App のプライバシー・DSA の申告）は、人が「終わった」を押す（`confirmAppStoreItem`）。
/// 決まった値（価格・配信の地域・カテゴリ・コンテンツの権利・プライバシーポリシーの URL）と Bundle ID の登録は、人が値を確かめて押したときだけ
/// 司令塔が API で書く（`applyAppStoreSettings`・`registerBundleId`）。配信中の版を見つけたら終わりの印（`releasedAt`）を付ける
/// （`docs/renewal/release.md` の「新しいアプリを載せる」）
public struct AppStoreSetupFile: StateFile {
    public static let formatVersion = 1

    /// チェックリストの項目（並びは画面に出す順）
    public enum ItemKind: String, Codable, Sendable, CaseIterable {
        /// Bundle ID を Certificates, Identifiers & Profiles に登録する
        case bundleId
        /// App Store Connect にアプリ（App のレコード）を作る
        case app
        /// コンテンツの権利の申告（`apps` の `contentRightsDeclaration`）
        case contentRights
        /// 主なカテゴリ（`appInfos` の `primaryCategory`）
        case category
        /// プライバシーポリシーの URL（`appInfoLocalizations` の `privacyPolicyUrl`）
        case privacyPolicy
        /// 価格（`appPriceSchedule`）
        case price
        /// 配信の地域（`appAvailabilityV2`）
        case availability
        /// 年齢制限の質問への答え（`ageRatingDeclaration`）
        case ageRating
        /// App のプライバシー（データの収集の申告）。API が無い
        case appPrivacy
        /// EU のデジタルサービス法（DSA）の申告。API が無い
        case digitalServicesAct

        /// API で終わったかを確かめられる（できないものは、人が「終わった」を押す）
        public var isVerifiable: Bool { self != .appPrivacy && self != .digitalServicesAct }

        /// 人が値を確かめて押したら、司令塔が API で書ける
        public var isWritable: Bool { Self.settingKinds.contains(self) || self == .bundleId }

        /// 決まった値を書く意図（`applyAppStoreSettings`）で書く項目
        public static let settingKinds: [Self] = [.contentRights, .category, .privacyPolicy, .price, .availability]

        /// アプリを作るまで（TestFlight に上げるのに要る）の項目か。ほかは初めての版を審査に出すまでに要る
        public var isNeededForApp: Bool { self == .bundleId || self == .app }
    }

    /// 項目の様子
    public enum ItemState: String, Codable, Sendable, CaseIterable {
        /// まだ終わっていない
        case todo
        /// 終わった（API で確かめた）
        case done
        /// API で読めない（鍵の役割が足りない・API が無い）。人が「終わった」を押すまで終わったとみなさない
        case unknown
    }

    /// 人の意図と、それを受け付けた時刻
    public struct Approval: Codable, Equatable, Sendable {
        public var approval: IntentReference
        public var at: Timestamp

        public init(approval: IntentReference, at: Timestamp) {
            self.approval = approval
            self.at = at
        }
    }

    /// チェックリストの 1 項目
    public struct Item: Codable, Equatable, Sendable {
        public var id: ItemKind
        public var state: ItemState
        /// 人が読む補足（今の値・読めなかった理由など）。500 文字まで
        public var note: String?
        /// 司令塔が今の様子を確かめた時刻（様子が変わったときだけ書き直す。記録を見回りのたびに書かないため）
        public var checkedAt: Timestamp
        /// 人が「終わった」を押した（API で確かめられない項目と、確かめが合わないときの上書き）
        public var confirmed: Approval?

        public init(id: ItemKind, state: ItemState, note: String? = nil, checkedAt: Timestamp, confirmed: Approval? = nil) {
            self.id = id
            self.state = state
            self.note = note
            self.checkedAt = checkedAt
            self.confirmed = confirmed
        }

        /// API で確かめたか、人が「終わった」を押した
        public var isDone: Bool { state == .done || confirmed != nil }

        public static let noteLimit = 500
    }

    /// App Store Connect のアプリ
    public struct App: Codable, Equatable, Sendable {
        /// App Store Connect のアプリの id（数字だけ）
        public var id: String
        public var name: String
        public var bundleId: String
        /// 主な言語（`ja`・`en-US` など）。読めなければ nil
        public var primaryLocale: String?

        public init(id: String, name: String, bundleId: String, primaryLocale: String? = nil) {
            self.id = id
            self.name = name
            self.bundleId = bundleId
            self.primaryLocale = primaryLocale
        }

        /// App Store Connect のアプリの id の形（数字だけ）
        public static func isID(_ text: String) -> Bool {
            (1...20).contains(text.utf8.count) && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }
    }

    /// 人が押した書き込みの結果の、送れなかった項目
    public struct Failure: Codable, Equatable, Sendable {
        public var item: ItemKind
        /// 人が読む理由（App Store Connect の説明など。鍵の値は含めない）。500 文字まで
        public var message: String

        public init(item: ItemKind, message: String) {
            self.item = item
            self.message = message
        }
    }

    /// Bundle ID を登録する人の意図（`registerBundleId`）。司令塔が送り終えたら `doneAt` が付く（断られたら `failures`）
    public struct BundleIDRequest: Codable, Equatable, Sendable {
        public var approval: IntentReference
        public var at: Timestamp
        public var identifier: String
        public var platform: BundleIDPlatform
        public var doneAt: Timestamp?
        public var failures: [Failure]?

        public init(
            approval: IntentReference,
            at: Timestamp,
            identifier: String,
            platform: BundleIDPlatform,
            doneAt: Timestamp? = nil,
            failures: [Failure]? = nil
        ) {
            self.approval = approval
            self.at = at
            self.identifier = identifier
            self.platform = platform
            self.doneAt = doneAt
            self.failures = failures
        }
    }

    /// 決まった値を書く人の意図（`applyAppStoreSettings`）。司令塔が送り終えたら `doneAt` が付き、断られた項目は `failures` に書く
    public struct SettingsRequest: Codable, Equatable, Sendable {
        public var approval: IntentReference
        public var at: Timestamp
        public var settings: AppStoreSettings
        public var doneAt: Timestamp?
        public var failures: [Failure]?

        public init(
            approval: IntentReference,
            at: Timestamp,
            settings: AppStoreSettings,
            doneAt: Timestamp? = nil,
            failures: [Failure]? = nil
        ) {
            self.approval = approval
            self.at = at
            self.settings = settings
            self.doneAt = doneAt
            self.failures = failures
        }
    }

    /// 確かめられなかった理由（確かめられたら消す）
    public struct Problem: Codable, Equatable, Sendable {
        public var message: String
        /// 人が直す必要がある（鍵が無い・断られた）なら true
        public var needsHuman: Bool
        public var at: Timestamp

        public init(message: String, needsHuman: Bool, at: Timestamp) {
            self.message = message
            self.needsHuman = needsHuman
            self.at = at
        }
    }

    public var repo: RepositoryFullName
    /// リポジトリの base のビルドの設定にある Bundle ID（見つけた順）。テストのターゲットのものも含む
    public var bundleIds: [String]
    /// App Store Connect で見つけたアプリ。まだ無ければ nil
    public var app: App?
    /// チェックリスト（項目ごとに 1 つ。`ItemKind` の順）
    public var items: [Item]
    /// 人が押した Bundle ID の登録（最後のもの）
    public var bundleIdRequest: BundleIDRequest?
    /// 人が押した決まった値の書き込み（最後のもの）
    public var settingsRequest: SettingsRequest?
    /// 人が「App Store に出さない」を押した（出すに戻したら nil）
    public var excluded: Approval?
    /// 配信中の版を見つけた時刻（初めての版が配信された。これより後は確かめない）
    public var releasedAt: Timestamp?
    /// App Store Connect で確かめて、様子が変わったのを書いた時刻（変わらなければ書き直さない）
    public var checkedAt: Timestamp?
    public var problem: Problem?
    public var createdAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        bundleIds: [String] = [],
        app: App? = nil,
        items: [Item] = [],
        bundleIdRequest: BundleIDRequest? = nil,
        settingsRequest: SettingsRequest? = nil,
        excluded: Approval? = nil,
        releasedAt: Timestamp? = nil,
        checkedAt: Timestamp? = nil,
        problem: Problem? = nil,
        createdAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.repo = repo
        self.bundleIds = bundleIds
        self.app = app
        self.items = items
        self.bundleIdRequest = bundleIdRequest
        self.settingsRequest = settingsRequest
        self.excluded = excluded
        self.releasedAt = releasedAt
        self.checkedAt = checkedAt
        self.problem = problem
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func item(_ kind: ItemKind) -> Item? { items.first { $0.id == kind } }

    public var isExcluded: Bool { excluded != nil }

    /// 準備を見ている（出さないと決めていない・初めての版をまだ配信していない）
    public var isActive: Bool { excluded == nil && releasedAt == nil }

    /// 終わっていない項目。`firstRelease` が false なら、アプリを作るまでの項目だけ（配信中の版が無いアプリでリリースを始めたら、残りも出す）
    public func pendingItems(firstRelease: Bool) -> [Item] {
        guard isActive else { return [] }
        let pending = items.filter { !$0.isDone }
        return firstRelease ? pending : pending.filter { $0.id.isNeededForApp }
    }

    /// 人が押した書き込みを、司令塔がまだ送り終えていない
    public var isWriting: Bool {
        (bundleIdRequest.map { $0.doneAt == nil } ?? false) || (settingsRequest.map { $0.doneAt == nil } ?? false)
    }

    /// リポジトリの Bundle ID の候補から、アプリ本体のものを選ぶ（テストのターゲットを外し、ほかの候補の前に付くもの・短いものを先に）
    public static func mainBundleID(among candidates: [String]) -> String? {
        let apps = candidates.filter { candidate in
            let last = candidate.split(separator: ".").last.map(String.init) ?? candidate
            return !last.hasSuffix("Tests")
        }
        return apps.min { lhs, rhs in
            let lhsPrefix = apps.contains { $0 != lhs && $0.hasPrefix(lhs + ".") }
            let rhsPrefix = apps.contains { $0 != rhs && $0.hasPrefix(rhs + ".") }
            if lhsPrefix != rhsPrefix { return lhsPrefix }
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return lhs < rhs
        }
    }

    /// Bundle ID の形（英数字・`-`・`.`。`$(…)` などの変数を含まない）
    public static func isBundleID(_ text: String) -> Bool {
        (1...155).contains(text.utf8.count) && !text.hasPrefix(".") && !text.hasSuffix(".") && !text.contains("..")
            && text.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
            }
    }

    public var violations: [String] {
        var violations: [String] = []
        if bundleIds.contains(where: { !Self.isBundleID($0) }) { violations.append("bundleIds の形が違う") }
        if Set(bundleIds).count != bundleIds.count { violations.append("bundleIds が重複している") }
        if let app {
            if !App.isID(app.id) { violations.append("app の id の形が違う") }
            if !Self.isBundleID(app.bundleId) { violations.append("app の bundleId の形が違う") }
            if app.name.isEmpty { violations.append("app の name が空") }
            if let locale = app.primaryLocale, !LocalizedText.isLocale(locale) { violations.append("app の primaryLocale の形が違う") }
        }
        if Set(items.map(\.id)).count != items.count { violations.append("items の項目が重複している") }
        if items.contains(where: { ($0.note?.isEmpty ?? false) || ($0.note?.unicodeScalars.count ?? 0) > Item.noteLimit }) {
            violations.append("items の note が空か \(Item.noteLimit) 文字を超えている")
        }
        if items.contains(where: { $0.id == .app && $0.confirmed != nil }) {
            violations.append("アプリの作成は API で確かめる（人の「終わった」を持たない）")
        }
        if let request = bundleIdRequest {
            if !Self.isBundleID(request.identifier) { violations.append("bundleIdRequest の identifier の形が違う") }
            violations += Self.problems(of: request.failures, doneAt: request.doneAt, name: "bundleIdRequest")
        }
        if let request = settingsRequest {
            violations += request.settings.problems.map { "settingsRequest の \($0)" }
            violations += Self.problems(of: request.failures, doneAt: request.doneAt, name: "settingsRequest")
            if request.failures?.contains(where: { !ItemKind.settingKinds.contains($0.item) }) ?? false {
                violations.append("settingsRequest の failures に決まった値でない項目がある")
            }
        }
        if problem?.message.isEmpty == true { violations.append("problem の message が空") }
        return violations
    }

    private static func problems(of failures: [Failure]?, doneAt: Timestamp?, name: String) -> [String] {
        guard let failures else { return [] }
        var problems: [String] = []
        if doneAt == nil { problems.append("\(name) の failures は送り終えた（doneAt がある）ときだけ持つ") }
        if failures.contains(where: { $0.message.isEmpty || $0.message.unicodeScalars.count > Item.noteLimit }) {
            problems.append("\(name) の failures の message が空か \(Item.noteLimit) 文字を超えている")
        }
        return problems
    }
}

/// Bundle ID のプラットフォーム（App Store Connect の `BundleIdPlatform`）
public enum BundleIDPlatform: String, Codable, Sendable, CaseIterable {
    case iOS
    case macOS
    /// iOS と macOS の両方（マルチプラットフォームのアプリ）
    case universal

    public var appStoreConnectValue: String {
        switch self {
        case .iOS: "IOS"
        case .macOS: "MAC_OS"
        case .universal: "UNIVERSAL"
        }
    }
}

/// コンテンツの権利の申告（App Store Connect の `contentRightsDeclaration`）
public enum ContentRightsDeclaration: String, Codable, Sendable, CaseIterable {
    /// 第三者のコンテンツを使わない
    case doesNotUseThirdPartyContent
    /// 第三者のコンテンツを使い、使う権利がある
    case usesThirdPartyContent

    public var appStoreConnectValue: String {
        switch self {
        case .doesNotUseThirdPartyContent: "DOES_NOT_USE_THIRD_PARTY_CONTENT"
        case .usesThirdPartyContent: "USES_THIRD_PARTY_CONTENT"
        }
    }
}

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

    public var contentRights: ContentRightsDeclaration?
    /// 主なカテゴリ（App Store Connect の `appCategories` の id。`PRODUCTIVITY` など）
    public var primaryCategory: String?
    /// 主なカテゴリのサブカテゴリ（ゲームの `GAMES_PUZZLE` など）。`primaryCategory` があるときだけ
    public var primarySubcategory: String?
    /// プライバシーポリシーの URL（https）。App Store Connect のすべての言語のうち、まだ書かれていないものに書く
    public var privacyPolicyUrl: String?
    public var price: Price?
    public var availability: Availability?

    public init(
        contentRights: ContentRightsDeclaration? = nil,
        primaryCategory: String? = nil,
        primarySubcategory: String? = nil,
        privacyPolicyUrl: String? = nil,
        price: Price? = nil,
        availability: Availability? = nil
    ) {
        self.contentRights = contentRights
        self.primaryCategory = primaryCategory
        self.primarySubcategory = primarySubcategory
        self.privacyPolicyUrl = privacyPolicyUrl
        self.price = price
        self.availability = availability
    }

    /// プライバシーポリシーの URL の長さの上限
    public static let urlLimit = 512

    /// 書く項目（チェックリストの項目）
    public var items: [AppStoreSetupFile.ItemKind] {
        var items: [AppStoreSetupFile.ItemKind] = []
        if contentRights != nil { items.append(.contentRights) }
        if primaryCategory != nil { items.append(.category) }
        if privacyPolicyUrl != nil { items.append(.privacyPolicy) }
        if price != nil { items.append(.price) }
        if availability != nil { items.append(.availability) }
        return items
    }

    /// 合わない点（何も書かない・カテゴリの形・URL の形）
    public var problems: [String] {
        var problems: [String] = []
        if items.isEmpty { problems.append("書く値が 1 つも無い") }
        if let primaryCategory, !Self.isCategory(primaryCategory) { problems.append("primaryCategory の形が違う") }
        if let primarySubcategory {
            if !Self.isCategory(primarySubcategory) { problems.append("primarySubcategory の形が違う") }
            if primaryCategory == nil { problems.append("primarySubcategory は primaryCategory と一緒に送る") }
        }
        if let privacyPolicyUrl, !Self.isURL(privacyPolicyUrl) { problems.append("privacyPolicyUrl が https の URL でない") }
        return problems
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
