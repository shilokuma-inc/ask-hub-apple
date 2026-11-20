import AskHubProtocol
import Foundation

// App Store Connect の App Review の情報（審査メモ・デモアカウント）。パスワードと連絡先は読まず、書かない

/// 版の App Review の情報（`appStoreReviewDetails`）。パスワードと連絡先は読まない
public struct AppStoreReviewDetail: Equatable, Sendable {
    public var id: String
    public var information: ReviewInformation

    public init(id: String, information: ReviewInformation) {
        self.id = id
        self.information = information
    }
}

extension AppStoreConnectClient {
    public func reviewDetail(of versionID: String) async throws(AppStoreConnectError) -> AppStoreReviewDetail? {
        try Self.checkID(versionID)
        // パスワードと連絡先は読まない（状態リポジトリに置かないため）
        let query = [URLQueryItem(name: "fields[appStoreReviewDetails]", value: "notes,demoAccountRequired,demoAccountName")]
        // まだ作っていない版は 404 か、200 で data が null
        let path = "v1/appStoreVersions/\(versionID)/appStoreReviewDetail"
        guard let response = try await getIfPresent(path, query: query, as: AppStoreConnectReviewDetailResponse.self),
              let item = response.data, Self.isID(item.id) else { return nil }
        let attributes = item.attributes
        return AppStoreReviewDetail(
            id: item.id,
            information: ReviewInformation(
                notes: attributes?.notes.flatMap { $0.isEmpty ? nil : $0 },
                demoAccountRequired: attributes?.demoAccountRequired,
                demoAccountName: attributes?.demoAccountName.flatMap { $0.isEmpty ? nil : $0 }
            )
        )
    }

    public func writeReviewDetail(
        _ detailID: String?,
        versionID: String,
        _ information: ReviewInformation
    ) async throws(AppStoreConnectError) {
        try Self.checkID(versionID)
        var attributes: [String: Any] = [:]
        if let notes = information.notes { attributes["notes"] = notes }
        if let required = information.demoAccountRequired { attributes["demoAccountRequired"] = required }
        if let name = information.demoAccountName { attributes["demoAccountName"] = name }
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
}
