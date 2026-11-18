import AskHubProtocol
import Foundation

// App Store Connect の審査の API（版の状態・ビルド・What's New・審査に出す・取り下げ・手動の配信）。
// 読み取りは見回りで、書き込みは人の意図を受け付けたときだけ使う（`docs/renewal/release.md` の「リリースを始めてから配信まで」）

/// App Store Connect の版（どの状態でも）
public struct AppStoreVersionInfo: Equatable, Sendable {
    /// App Store Connect の版の id
    public var id: String
    public var platform: AppStorePlatform
    /// 版の番号（`versionString`）。人が App Store Connect で書いたものなので、形を確かめずに持つ
    public var versionString: String
    public var state: AppStoreVersionState
    public var releaseType: AppStoreReleaseType?
    /// 選んであるビルドの番号。選んでいない・読めなければ nil
    public var build: String?
    /// 選んであるビルドを上げた時刻
    public var uploadedAt: Date?

    public init(
        id: String,
        platform: AppStorePlatform,
        versionString: String,
        state: AppStoreVersionState,
        releaseType: AppStoreReleaseType? = nil,
        build: String? = nil,
        uploadedAt: Date? = nil
    ) {
        self.id = id
        self.platform = platform
        self.versionString = versionString
        self.state = state
        self.releaseType = releaseType
        self.build = build
        self.uploadedAt = uploadedAt
    }

    public var version: MarketingVersion? { MarketingVersion(rawValue: versionString) }

    /// 編集できる（版の番号・ビルド・What's New を変えて審査に出せる）状態
    public var isEditable: Bool {
        [.prepareForSubmission, .readyForReview, .developerRejected, .rejected, .metadataRejected, .invalidBinary].contains(state)
    }
}

/// 版に入れる中身（版の番号・配信の方式・ビルド）。`earliestReleaseDate` は `scheduled` のときだけ送り、ほかは消す
public struct AppStoreVersionChange: Equatable, Sendable {
    public var version: MarketingVersion
    public var releaseType: AppStoreReleaseType
    public var earliestReleaseDate: Date?
    /// 選ぶビルドの id
    public var buildID: String

    public init(version: MarketingVersion, releaseType: AppStoreReleaseType, earliestReleaseDate: Date? = nil, buildID: String) {
        self.version = version
        self.releaseType = releaseType
        self.earliestReleaseDate = earliestReleaseDate
        self.buildID = buildID
    }

    /// 本文の attributes（`versionString`・`releaseType`・`earliestReleaseDate`）
    var attributes: [String: Any] {
        var date: Any = NSNull()
        if releaseType == .scheduled, let earliestReleaseDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.string(from: earliestReleaseDate)
        }
        return ["versionString": version.rawValue, "releaseType": releaseType.appStoreConnectValue, "earliestReleaseDate": date]
    }
}

/// App Store Connect のビルド
public struct AppStoreBuild: Equatable, Sendable {
    public var id: String
    public var platform: AppStorePlatform
    /// ビルドの番号（`CFBundleVersion`）
    public var number: String
    public var uploadedAt: Date?
    /// 輸出コンプライアンスの答え。答えていなければ nil
    public var usesNonExemptEncryption: Bool?
    public var expired: Bool

    public init(id: String, platform: AppStorePlatform, number: String, uploadedAt: Date?, usesNonExemptEncryption: Bool?, expired: Bool) {
        self.id = id
        self.platform = platform
        self.number = number
        self.uploadedAt = uploadedAt
        self.usesNonExemptEncryption = usesNonExemptEncryption
        self.expired = expired
    }
}

/// 版の 1 つの言語の掲載文（What's New だけを読む）
public struct AppStoreLocalization: Equatable, Sendable {
    public var id: String
    public var locale: String
    public var whatsNew: String?

    public init(id: String, locale: String, whatsNew: String?) {
        self.id = id
        self.locale = locale
        self.whatsNew = whatsNew
    }
}

/// 審査の提出（reviewSubmission）の状態
public enum AppStoreReviewSubmissionState: String, Equatable, Sendable, CaseIterable {
    case readyForReview = "READY_FOR_REVIEW"
    case waitingForReview = "WAITING_FOR_REVIEW"
    case inReview = "IN_REVIEW"
    case unresolvedIssues = "UNRESOLVED_ISSUES"
    case canceling = "CANCELING"
    case completing = "COMPLETING"
    case complete = "COMPLETE"
}

/// 審査の提出（reviewSubmission）
public struct AppStoreReviewSubmission: Equatable, Sendable {
    public var id: String
    public var platform: AppStorePlatform?
    public var state: AppStoreReviewSubmissionState
    /// 提出に入っている版の id（無ければ nil）
    public var versionID: String?

    public init(id: String, platform: AppStorePlatform?, state: AppStoreReviewSubmissionState, versionID: String?) {
        self.id = id
        self.platform = platform
        self.state = state
        self.versionID = versionID
    }
}

/// App Store Connect の審査の API（テストでは差し替える）
public protocol AppStoreConnectSubmitting: AppStoreConnectReading {
    /// 置き換わった版（`REPLACED_WITH_NEW_VERSION`）のほかの、すべての版（審査の見張りと配信の検知を 1 回で読む）
    func versions(of appID: String) async throws(AppStoreConnectError) -> [AppStoreVersionInfo]
    /// その版の番号の、処理を終えた（`VALID`）ビルド（新しく上げた順）
    func builds(of appID: String, version: MarketingVersion) async throws(AppStoreConnectError) -> [AppStoreBuild]
    /// 版の言語ごとの掲載文
    func localizations(of versionID: String) async throws(AppStoreConnectError) -> [AppStoreLocalization]
    /// 版を作る
    func createVersion(
        of appID: String,
        platform: AppStorePlatform,
        _ change: AppStoreVersionChange
    ) async throws(AppStoreConnectError) -> AppStoreVersionInfo
    /// 編集できる版の番号・配信の方式・ビルドを直す
    func updateVersion(_ versionID: String, _ change: AppStoreVersionChange) async throws(AppStoreConnectError)
    func updateWhatsNew(_ localizationID: String, text: String) async throws(AppStoreConnectError)
    /// 終わっていない提出（審査に出す前・審査を待っている・審査中・断られたもの）
    func reviewSubmissions(of appID: String, platform: AppStorePlatform) async throws(AppStoreConnectError) -> [AppStoreReviewSubmission]
    func createReviewSubmission(of appID: String, platform: AppStorePlatform) async throws(AppStoreConnectError) -> AppStoreReviewSubmission
    func addToReviewSubmission(_ submissionID: String, versionID: String) async throws(AppStoreConnectError)
    /// 提出する（`submitted: true`）
    func submitReviewSubmission(_ submissionID: String) async throws(AppStoreConnectError)
    /// 取り下げる（`canceled: true`）
    func cancelReviewSubmission(_ submissionID: String) async throws(AppStoreConnectError)
    /// 承認された（Pending Developer Release の）版を配信する。取り消せない
    func requestRelease(of versionID: String) async throws(AppStoreConnectError)
}

extension AppStoreConnectClient: AppStoreConnectSubmitting {
    public func versions(of appID: String) async throws(AppStoreConnectError) -> [AppStoreVersionInfo] {
        try Self.checkID(appID)
        let states = AppStoreVersionState.allCases.filter { $0 != .replacedWithNewVersion }.map(\.appStoreConnectValue)
        let query = [
            URLQueryItem(name: "filter[appVersionState]", value: states.joined(separator: ",")),
            URLQueryItem(name: "include", value: "build"),
            URLQueryItem(name: "fields[appStoreVersions]", value: "platform,versionString,appVersionState,releaseType,build"),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate"),
            URLQueryItem(name: "limit", value: String(Self.pageLimit))
        ]
        let response = try await get("v1/apps/\(appID)/appStoreVersions", query: query, as: AppStoreConnectVersionsResponse.self)
        return Self.versions(response)
    }

    /// 応答から版を読む。知らないプラットフォーム・状態の版は飛ばす
    static func versions(_ response: AppStoreConnectVersionsResponse) -> [AppStoreVersionInfo] {
        let builds = Dictionary(
            (response.included ?? []).filter { $0.type == "builds" }.map { ($0.id, $0.attributes) },
            uniquingKeysWith: { first, _ in first }
        )
        return response.data.compactMap { item in
            guard isID(item.id), let attributes = item.attributes,
                  let platform = attributes.platform.flatMap(AppStorePlatform.init(appStoreConnectValue:)),
                  let state = attributes.appVersionState.flatMap(AppStoreVersionState.init(appStoreConnectValue:)),
                  let versionString = attributes.versionString else { return nil }
            let build = item.relationships?.build?.data.flatMap { builds[$0.id, default: nil] }
            return AppStoreVersionInfo(
                id: item.id,
                platform: platform,
                versionString: versionString,
                state: state,
                releaseType: attributes.releaseType.flatMap { value in
                    AppStoreReleaseType.allCases.first { $0.appStoreConnectValue == value }
                },
                build: build?.version.flatMap { ReleaseFile.isBuildNumber($0) ? $0 : nil },
                uploadedAt: build?.uploadedDate.flatMap(Self.date)
            )
        }
    }

    public func builds(of appID: String, version: MarketingVersion) async throws(AppStoreConnectError) -> [AppStoreBuild] {
        try Self.checkID(appID)
        let query = [
            URLQueryItem(name: "filter[app]", value: appID),
            URLQueryItem(name: "filter[preReleaseVersion.version]", value: version.rawValue),
            URLQueryItem(name: "filter[processingState]", value: "VALID"),
            URLQueryItem(name: "sort", value: "-uploadedDate"),
            URLQueryItem(name: "include", value: "preReleaseVersion"),
            URLQueryItem(name: "fields[builds]", value: "version,uploadedDate,expired,usesNonExemptEncryption,preReleaseVersion"),
            URLQueryItem(name: "fields[preReleaseVersions]", value: "platform,version"),
            URLQueryItem(name: "limit", value: "50")
        ]
        let response = try await get("v1/builds", query: query, as: AppStoreConnectBuildsResponse.self)
        let platforms = Dictionary(
            (response.included ?? []).filter { $0.type == "preReleaseVersions" }.map { ($0.id, $0.attributes) },
            uniquingKeysWith: { first, _ in first }
        )
        return response.data.compactMap { item in
            guard Self.isID(item.id), let attributes = item.attributes,
                  let number = attributes.version, ReleaseFile.isBuildNumber(number),
                  let train = item.relationships?.preReleaseVersion?.data.flatMap({ platforms[$0.id, default: nil] }),
                  train.version == version.rawValue,
                  let platform = train.platform.flatMap(AppStorePlatform.init(appStoreConnectValue:)) else { return nil }
            return AppStoreBuild(
                id: item.id,
                platform: platform,
                number: number,
                uploadedAt: attributes.uploadedDate.flatMap(Self.date),
                usesNonExemptEncryption: attributes.usesNonExemptEncryption,
                expired: attributes.expired ?? false
            )
        }
    }

    public func localizations(of versionID: String) async throws(AppStoreConnectError) -> [AppStoreLocalization] {
        try Self.checkID(versionID)
        let query = [
            URLQueryItem(name: "fields[appStoreVersionLocalizations]", value: "locale,whatsNew"),
            URLQueryItem(name: "limit", value: "50")
        ]
        let response = try await get(
            "v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", query: query, as: AppStoreConnectLocalizationsResponse.self
        )
        return response.data.compactMap { item in
            guard Self.isID(item.id), let locale = item.attributes?.locale, LocalizedText.isLocale(locale) else { return nil }
            return AppStoreLocalization(id: item.id, locale: locale, whatsNew: item.attributes?.whatsNew)
        }
    }

    public func createVersion(
        of appID: String,
        platform: AppStorePlatform,
        _ change: AppStoreVersionChange
    ) async throws(AppStoreConnectError) -> AppStoreVersionInfo {
        try Self.checkID(appID)
        try Self.checkID(change.buildID)
        let body = try Self.document(
            "appStoreVersions",
            attributes: change.attributes.merging(["platform": platform.appStoreConnectValue]) { current, _ in current },
            relationships: ["app": ("apps", appID), "build": ("builds", change.buildID)]
        )
        let data = try await send("POST", "v1/appStoreVersions", body: body)
        guard let created = try? JSONDecoder().decode(AppStoreConnectCreated.self, from: data), Self.isID(created.data.id) else {
            throw .malformed("作った版の応答")
        }
        return AppStoreVersionInfo(
            id: created.data.id,
            platform: platform,
            versionString: change.version.rawValue,
            state: .prepareForSubmission,
            releaseType: change.releaseType
        )
    }

    public func updateVersion(_ versionID: String, _ change: AppStoreVersionChange) async throws(AppStoreConnectError) {
        try Self.checkID(versionID)
        try Self.checkID(change.buildID)
        let body = try Self.document(
            "appStoreVersions", id: versionID, attributes: change.attributes, relationships: ["build": ("builds", change.buildID)]
        )
        _ = try await send("PATCH", "v1/appStoreVersions/\(versionID)", body: body)
    }

    public func updateWhatsNew(_ localizationID: String, text: String) async throws(AppStoreConnectError) {
        try Self.checkID(localizationID)
        let body = try Self.document("appStoreVersionLocalizations", id: localizationID, attributes: ["whatsNew": text])
        _ = try await send("PATCH", "v1/appStoreVersionLocalizations/\(localizationID)", body: body)
    }

    public func reviewSubmissions(
        of appID: String,
        platform: AppStorePlatform
    ) async throws(AppStoreConnectError) -> [AppStoreReviewSubmission] {
        try Self.checkID(appID)
        let states: [AppStoreReviewSubmissionState] = [.readyForReview, .waitingForReview, .inReview, .unresolvedIssues]
        let query = [
            URLQueryItem(name: "filter[app]", value: appID),
            URLQueryItem(name: "filter[platform]", value: platform.appStoreConnectValue),
            URLQueryItem(name: "filter[state]", value: states.map(\.rawValue).joined(separator: ",")),
            URLQueryItem(name: "include", value: "appStoreVersionForReview"),
            URLQueryItem(name: "limit", value: "50")
        ]
        let response = try await get("v1/reviewSubmissions", query: query, as: AppStoreConnectSubmissionsResponse.self)
        // 絞り込みが効かなかったときに、終わった提出を使わない
        return response.data.compactMap(Self.submission).filter { states.contains($0.state) }
    }

    public func createReviewSubmission(
        of appID: String,
        platform: AppStorePlatform
    ) async throws(AppStoreConnectError) -> AppStoreReviewSubmission {
        try Self.checkID(appID)
        let body = try Self.document(
            "reviewSubmissions", attributes: ["platform": platform.appStoreConnectValue], relationships: ["app": ("apps", appID)]
        )
        let data = try await send("POST", "v1/reviewSubmissions", body: body)
        guard let created = try? JSONDecoder().decode(AppStoreConnectCreated.self, from: data), Self.isID(created.data.id) else {
            throw .malformed("作った提出の応答")
        }
        return AppStoreReviewSubmission(id: created.data.id, platform: platform, state: .readyForReview, versionID: nil)
    }

    public func addToReviewSubmission(_ submissionID: String, versionID: String) async throws(AppStoreConnectError) {
        try Self.checkID(submissionID)
        try Self.checkID(versionID)
        let body = try Self.document(
            "reviewSubmissionItems",
            relationships: ["reviewSubmission": ("reviewSubmissions", submissionID), "appStoreVersion": ("appStoreVersions", versionID)]
        )
        _ = try await send("POST", "v1/reviewSubmissionItems", body: body)
    }

    public func submitReviewSubmission(_ submissionID: String) async throws(AppStoreConnectError) {
        try await patchReviewSubmission(submissionID, attributes: ["submitted": true])
    }

    public func cancelReviewSubmission(_ submissionID: String) async throws(AppStoreConnectError) {
        try await patchReviewSubmission(submissionID, attributes: ["canceled": true])
    }

    public func requestRelease(of versionID: String) async throws(AppStoreConnectError) {
        try Self.checkID(versionID)
        let body = try Self.document("appStoreVersionReleaseRequests", relationships: ["appStoreVersion": ("appStoreVersions", versionID)])
        _ = try await send("POST", "v1/appStoreVersionReleaseRequests", body: body)
    }

    private func patchReviewSubmission(_ submissionID: String, attributes: [String: Any]) async throws(AppStoreConnectError) {
        try Self.checkID(submissionID)
        let body = try Self.document("reviewSubmissions", id: submissionID, attributes: attributes)
        _ = try await send("PATCH", "v1/reviewSubmissions/\(submissionID)", body: body)
    }

    // MARK: - 形

    static func submission(_ item: AppStoreConnectSubmissionsResponse.Item) -> AppStoreReviewSubmission? {
        guard isID(item.id), let state = item.attributes?.state.flatMap(AppStoreReviewSubmissionState.init(rawValue:)) else {
            return nil
        }
        return AppStoreReviewSubmission(
            id: item.id,
            platform: item.attributes?.platform.flatMap(AppStorePlatform.init(appStoreConnectValue:)),
            state: state,
            versionID: item.relationships?.appStoreVersionForReview?.data?.id
        )
    }

    /// App Store Connect の資源の id（英数字と `-`）。パスと本文に入れるので、ほかの文字を含むものは使わない
    static func isID(_ text: String) -> Bool {
        (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: "-")
        }
    }

    static func checkID(_ text: String) throws(AppStoreConnectError) {
        guard isID(text) else { throw .malformed("id の形が違う") }
    }

    /// JSON:API の本文（`{"data": {type, id, attributes, relationships}}`）。`relationships` は名前ごとの（型, id）
    static func document(
        _ type: String,
        id: String? = nil,
        attributes: [String: Any]? = nil,
        relationships: [String: (type: String, id: String)] = [:]
    ) throws(AppStoreConnectError) -> Data {
        var data: [String: Any] = ["type": type]
        if let id { data["id"] = id }
        if let attributes { data["attributes"] = attributes }
        if !relationships.isEmpty {
            data["relationships"] = relationships.mapValues { link in ["data": ["type": link.type, "id": link.id]] }
        }
        do {
            return try JSONSerialization.data(withJSONObject: ["data": data], options: [.sortedKeys])
        } catch {
            throw .malformed("本文を作れない")
        }
    }
}

/// App Store Connect の errors の本文から、人に見せる説明を取り出す
enum AppStoreConnectErrors {
    static let limit = 400

    private struct Item: Decodable {
        var title: String?
        var detail: String?
    }

    private struct Body: Decodable {
        var errors: [Item]?
    }

    static func detail(_ data: Data) -> String {
        guard let body = try? JSONDecoder().decode(Body.self, from: data), let errors = body.errors, !errors.isEmpty else {
            return "理由は返されなかった"
        }
        let text = errors.compactMap { $0.detail ?? $0.title }.joined(separator: " / ")
        guard !text.isEmpty else { return "理由は返されなかった" }
        return text.unicodeScalars.count > limit ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit))) + "…" : text
    }
}
