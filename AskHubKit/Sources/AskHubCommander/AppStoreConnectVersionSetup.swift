import AskHubProtocol
import Foundation

// 初めての版の、版の項目の API（サポート URL・マーケティング URL・著作権表示・App Review の連絡先）。
// 版の枠（`submissions/<版>.json` の `appStoreVersions`）があるときだけ読み、書き込みは人の意図を受け付けたときだけ使う
// （`docs/renewal/release.md` の「新しいアプリを載せる」）

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

    public init(copyright: String? = nil, localizations: [Localization] = [], missingReviewContact: [ReviewContactField] = []) {
        self.copyright = copyright
        self.localizations = localizations
        self.missingReviewContact = missingReviewContact
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
        // 連絡先は、入れてあるかだけを見る（値は返さない）。App Review の情報がまだ無ければ 404 か data が null
        let fields = ReviewContactField.allCases.map(\.rawValue).joined(separator: ",")
        let detail = try await getIfPresent(
            "v1/appStoreVersions/\(versionID)/appStoreReviewDetail",
            query: [URLQueryItem(name: "fields[appStoreReviewDetails]", value: fields)],
            as: AppStoreConnectReviewContactResponse.self
        )
        let contact = detail?.data?.attributes ?? [:]
        state.missingReviewContact = ReviewContactField.allCases.filter { field in
            guard case let .string(value)? = contact[field.rawValue] else { return true }
            return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return state
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

/// App Review の情報の連絡先（値は JSON の値のまま読み、入れてあるかだけを見て捨てる）
struct AppStoreConnectReviewContactResponse: Decodable {
    var data: AppStoreConnectResource<[String: JSONValue]>?
}
