import AskHubProtocol
import Foundation

// 初めての版の、版の項目の API（サポート URL・マーケティング URL・著作権表示・App Review の連絡先）。
// 版の枠（`submissions/<版>.json` の `appStoreVersions`）があるときだけ読み、書き込みは人の意図を受け付けたときだけ使う
// （`docs/renewal/release.md` の「新しいアプリを載せる」）。App Review の連絡先は、同じ鍵のほかのアプリの版から写すときだけ値を読み、
// 値はメモリーの中だけで使う（記録・ログ・通知に出さない）

/// App Review の連絡先の欄（値は読んでも持たない。状態リポジトリに置かないため）
public enum ReviewContactField: String, CaseIterable, Sendable {
    case firstName = "contactFirstName"
    case lastName = "contactLastName"
    case phone = "contactPhone"
    case email = "contactEmail"

    var label: String {
        switch self {
        case .firstName: "名"
        case .lastName: "姓"
        case .phone: "電話番号"
        case .email: "メールアドレス"
        }
    }
}

/// App Review の連絡先の値。ほかのアプリの版から写すときだけ読み、メモリーの中だけで使う。
/// 状態リポジトリ・ログ・通知に出さないため、文字列にしたとき（`"\(contact)"`・`dump`）は値を伏せる
public struct ReviewContact: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let values: [ReviewContactField: String]

    public init(values: [ReviewContactField: String]) {
        self.values = values.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 入れていない欄
    public var missing: [ReviewContactField] { ReviewContactField.allCases.filter { values[$0] == nil } }

    public var isComplete: Bool { missing.isEmpty }

    public var description: String { "App Review の連絡先（値は出さない）" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// 版の App Review の情報の、連絡先
public struct AppStoreReviewContact: Equatable, Sendable {
    /// App Review の情報（`appStoreReviewDetails`）の id
    public var detailID: String
    public var contact: ReviewContact

    public init(detailID: String, contact: ReviewContact) {
        self.detailID = detailID
        self.contact = contact
    }
}

/// App Store Connect で読んだ、1 つの版（枠）の準備の様子
public struct AppStoreVersionSetupState: Equatable, Sendable {
    /// 版の 1 つの言語（サポート URL とマーケティング URL だけを読む）
    public struct Localization: Equatable, Sendable {
        public var id: String
        public var locale: String
        public var supportUrl: String?
        public var marketingUrl: String?

        public init(id: String, locale: String, supportUrl: String? = nil, marketingUrl: String? = nil) {
            self.id = id
            self.locale = locale
            self.supportUrl = supportUrl
            self.marketingUrl = marketingUrl
        }
    }

    /// 著作権表示。書いていなければ nil
    public var copyright: String?
    public var localizations: [Localization]
    /// App Review の連絡先のうち、入れていない欄（App Review の情報が無ければ、すべて）。入れた値は持たない
    public var missingReviewContact: [ReviewContactField]
    /// App Review の情報（`appStoreReviewDetails`）の id。まだ無ければ nil（連絡先を写すときに作る）
    public var reviewDetailID: String?

    public init(
        copyright: String? = nil,
        localizations: [Localization] = [],
        missingReviewContact: [ReviewContactField] = [],
        reviewDetailID: String? = nil
    ) {
        self.copyright = copyright
        self.localizations = localizations
        self.missingReviewContact = missingReviewContact
        self.reviewDetailID = reviewDetailID
    }
}

extension AppStoreConnectClient {
    public func versionSetupState(of versionID: String) async throws(AppStoreConnectError) -> AppStoreVersionSetupState {
        try Self.checkID(versionID)
        var state = AppStoreVersionSetupState()
        let version = try await get(
            "v1/appStoreVersions/\(versionID)",
            query: [URLQueryItem(name: "fields[appStoreVersions]", value: "copyright")],
            as: AppStoreConnectSingle<AppStoreConnectCopyrightAttributes>.self
        )
        state.copyright = Self.nonEmpty(version.data.attributes?.copyright)
        let localizations = try await get(
            "v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            query: [
                URLQueryItem(name: "fields[appStoreVersionLocalizations]", value: "locale,supportUrl,marketingUrl"),
                URLQueryItem(name: "limit", value: "50")
            ],
            as: AppStoreConnectVersionURLsResponse.self
        )
        state.localizations = localizations.data.compactMap { item in
            guard Self.isID(item.id), let locale = item.attributes?.locale, LocalizedText.isLocale(locale) else { return nil }
            return .init(
                id: item.id,
                locale: locale,
                supportUrl: Self.nonEmpty(item.attributes?.supportUrl),
                marketingUrl: Self.nonEmpty(item.attributes?.marketingUrl)
            )
        }
        // 連絡先は、入れてあるかだけを返す（値は返さない）
        let detail = try await reviewContact(of: versionID)
        state.reviewDetailID = detail?.detailID
        state.missingReviewContact = detail?.contact.missing ?? ReviewContactField.allCases
        return state
    }

    /// 版の App Review の連絡先。App Review の情報がまだ無ければ（404 か data が null）nil。パスワード・メモは求めない
    public func reviewContact(of versionID: String) async throws(AppStoreConnectError) -> AppStoreReviewContact? {
        try Self.checkID(versionID)
        let fields = ReviewContactField.allCases.map(\.rawValue).joined(separator: ",")
        let detail = try await getIfPresent(
            "v1/appStoreVersions/\(versionID)/appStoreReviewDetail",
            query: [URLQueryItem(name: "fields[appStoreReviewDetails]", value: fields)],
            as: AppStoreConnectReviewContactResponse.self
        )
        guard let item = detail?.data, Self.isID(item.id) else { return nil }
        let attributes = item.attributes ?? [:]
        var values: [ReviewContactField: String] = [:]
        for field in ReviewContactField.allCases {
            if case let .string(value)? = attributes[field.rawValue] { values[field] = value }
        }
        return AppStoreReviewContact(detailID: item.id, contact: ReviewContact(values: values))
    }

    /// 版の App Review の連絡先のうち、`fields` の欄だけを書く（App Review の情報が無ければ作る）
    public func writeReviewContact(
        _ contact: ReviewContact,
        fields: [ReviewContactField],
        detailID: String?,
        versionID: String
    ) async throws(AppStoreConnectError) {
        try Self.checkID(versionID)
        var attributes: [String: Any] = [:]
        for field in fields {
            if let value = contact.values[field] { attributes[field.rawValue] = value }
        }
        guard !attributes.isEmpty else { return }
        if let detailID {
            try Self.checkID(detailID)
            let body = try Self.document("appStoreReviewDetails", id: detailID, attributes: attributes)
            _ = try await send("PATCH", "v1/appStoreReviewDetails/\(detailID)", body: body)
        } else {
            let body = try Self.document(
                "appStoreReviewDetails", attributes: attributes, relationships: ["appStoreVersion": ("appStoreVersions", versionID)]
            )
            _ = try await send("POST", "v1/appStoreReviewDetails", body: body)
        }
    }

    /// この鍵で見られるすべてのアプリ（連絡先を写すもとを探す）。ページを最後まで追う
    public func allApps() async throws(AppStoreConnectError) -> [AppStoreApp] {
        var query = [
            URLQueryItem(name: "fields[apps]", value: "bundleId,name"),
            URLQueryItem(name: "limit", value: String(Self.pageLimit))
        ]
        var apps: [AppStoreApp] = []
        for _ in 0..<20 {
            let page = try await get("v1/apps", query: query, as: AppStoreConnectAppsPage.self)
            apps += page.data.compactMap { app in
                guard Self.isAppID(app.id), let bundleID = app.attributes?.bundleId else { return nil }
                return AppStoreApp(id: app.id, bundleId: bundleID, name: app.attributes?.name ?? bundleID)
            }
            guard let next = page.links?.next.flatMap(URLComponents.init(string:))?.queryItems, !next.isEmpty else { break }
            query = next
        }
        return apps
    }

    public func setCopyright(_ text: String, versionID: String) async throws(AppStoreConnectError) {
        try Self.checkID(versionID)
        guard AppStoreSettings.isCopyright(text) else { throw .malformed("著作権表示の形が違う") }
        let body = try Self.document("appStoreVersions", id: versionID, attributes: ["copyright": text])
        _ = try await send("PATCH", "v1/appStoreVersions/\(versionID)", body: body)
    }

    public func setVersionURLs(support: String?, marketing: String?, localizationID: String) async throws(AppStoreConnectError) {
        try Self.checkID(localizationID)
        var attributes: [String: Any] = [:]
        for (key, url) in [("supportUrl", support), ("marketingUrl", marketing)] {
            guard let url else { continue }
            guard AppStoreSettings.isURL(url) else { throw .malformed("\(key) の形が違う") }
            attributes[key] = url
        }
        guard !attributes.isEmpty else { return }
        let body = try Self.document("appStoreVersionLocalizations", id: localizationID, attributes: attributes)
        _ = try await send("PATCH", "v1/appStoreVersionLocalizations/\(localizationID)", body: body)
    }

    /// 空の文字列は無いものとして持つ（App Store Connect は空の文字列か null で返す）
    static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct AppStoreConnectCopyrightAttributes: Decodable {
    var copyright: String?
}

struct AppStoreConnectVersionURLsResponse: Decodable {
    struct Attributes: Decodable {
        var locale: String?
        var supportUrl: String?
        var marketingUrl: String?
    }

    var data: [AppStoreConnectResource<Attributes>]
}

/// App Review の情報の連絡先（値は JSON の値のまま読む）
struct AppStoreConnectReviewContactResponse: Decodable {
    var data: AppStoreConnectResource<[String: JSONValue]>?
}

struct AppStoreConnectAppsPage: Decodable {
    struct Links: Decodable {
        var next: String?
    }

    var data: [AppStoreConnectResource<AppStoreConnectAppsResponse.Attributes>]
    var links: Links?
}
