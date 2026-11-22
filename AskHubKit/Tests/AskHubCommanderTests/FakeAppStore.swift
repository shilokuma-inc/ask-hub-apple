@testable import AskHubCommander
import AskHubProtocol
import Foundation
import os

/// 決めたアプリ・版・ビルド・掲載文を返し、読んだ回数と書き込みを残す
final class FakeAppStore: AppStoreConnecting {
    struct State {
        var apps: [AppStoreApp] = []
        /// 配信中の版（`versions(of:)` は、`others` の後に配信中の版として返す）
        var versions: [LiveAppVersion] = []
        /// 配信中のほかの版（審査中など）
        var others: [AppStoreVersionInfo] = []
        var builds: [AppStoreBuild] = []
        var localizations: [String: [AppStoreLocalization]] = [:]
        /// 版の id ごとの App Review の情報
        var reviewDetails: [String: AppStoreReviewDetail] = [:]
        /// 掲載文の id ごとのスクショの組（配置を作る・消すと変わる）
        var screenshotSets: [String: [AppStoreScreenshotSet]] = [:]
        /// 表示サイズ（配置グループ）ごとのプラットフォーム
        var displayTypePlatforms: [String: AppStorePlatform] = [
            "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE": .iOS, "IPHONE_DUO_PROFILE": .iOS, "MAC_PROFILE": .macOS
        ]
        /// ライブラリの画像（参照名ごと。上げると足す）
        var libraryImages: [String: [AppStoreLibraryImage]] = [:]
        /// 上げた画像の、上げた直後の処理の様子（既定はすぐ置ける）
        var sentState = "PREPARE_FOR_SUBMISSION"
        /// 決めると、ライブラリの画像を読めずにこれを投げる
        var libraryFailure: AppStoreConnectError?
        /// 決めると、アプリを探せずにこれを投げる
        var appsFailure: AppStoreConnectError?
        /// 決めると、上げた画像の処理の様子（id で読む）を読めずにこれを投げる
        var sentImageFailure: AppStoreConnectError?
        /// 作った配置の数（配置の id の番号）
        var placementCount = 0
        /// スクショの画像（URL ごと）
        var images: [URL: Data] = [:]
        var submissions: [AppStoreReviewSubmission] = []
        /// 書き込みの記録（「createVersion 1.4.0」など）
        var writes: [String] = []
        /// 決めると、書き込みをこれで断る
        var refusal: AppStoreConnectError?
        var reads = 0
        /// 登録してある Bundle ID
        var bundleIDs: [String] = []
        /// 決めると、Bundle ID の読み取りをこれで断る
        var bundleIDRefusal: AppStoreConnectError?
        /// アプリの準備の様子（書き込むと変わる）
        var setup = AppStoreSetupState()
        /// 版の枠ごとの、初めての版の項目の様子（書き込むと変わる）
        var versionSetups: [String: AppStoreVersionSetupState] = [:]
        /// ほかのアプリの版（アプリの id ごと）。無いアプリは `others` と配信中の版を返す
        var versionsByApp: [String: [AppStoreVersionInfo]] = [:]
        /// 版ごとの App Review の連絡先（写すもと）
        var reviewContacts: [String: AppStoreReviewContact] = [:]
    }

    let keyID = "ABCDE12345"
    let state = OSAllocatedUnfairLock(initialState: State())

    func apps(bundleIDs: [String]) async throws(AppStoreConnectError) -> [AppStoreApp] {
        if let failure = state.withLock({ $0.appsFailure }) { throw failure }
        return state.withLock { $0.apps.filter { bundleIDs.contains($0.bundleId) } }
    }

    func liveVersions(of appID: String) async throws(AppStoreConnectError) -> [LiveAppVersion] {
        state.withLock { state in
            state.reads += 1
            return state.versions
        }
    }

    func versions(of appID: String) async throws(AppStoreConnectError) -> [AppStoreVersionInfo] {
        state.withLock { state in
            state.reads += 1
            if let versions = state.versionsByApp[appID] { return versions }
            return state.others + state.versions.enumerated().map { index, live in
                AppStoreVersionInfo(
                    id: "live-\(index)",
                    platform: live.platform,
                    versionString: live.version.rawValue,
                    state: .readyForDistribution,
                    build: live.build,
                    uploadedAt: live.uploadedAt
                )
            }
        }
    }

    func builds(of appID: String, version: MarketingVersion) async throws(AppStoreConnectError) -> [AppStoreBuild] {
        state.withLock { $0.builds }
    }

    func localizations(of versionID: String) async throws(AppStoreConnectError) -> [AppStoreLocalization] {
        state.withLock { $0.localizations[versionID] ?? [] }
    }

    private func write(_ entry: String) throws(AppStoreConnectError) {
        let refusal = state.withLock { state -> AppStoreConnectError? in
            if let refusal = state.refusal { return refusal }
            state.writes.append(entry)
            return nil
        }
        if let refusal { throw refusal }
    }

    func createVersion(
        of appID: String,
        platform: AppStorePlatform,
        _ change: AppStoreVersionChange
    ) async throws(AppStoreConnectError) -> AppStoreVersionInfo {
        try write("createVersion \(platform.rawValue) \(change.version) \(change.releaseType?.rawValue ?? "-") \(change.buildID ?? "-")")
        let created = AppStoreVersionInfo(
            id: "v-\(change.version.rawValue.replacingOccurrences(of: ".", with: "-"))",
            platform: platform,
            versionString: change.version.rawValue,
            state: .prepareForSubmission
        )
        state.withLock { $0.others.append(created) }
        return created
    }

    func updateVersion(_ versionID: String, _ change: AppStoreVersionChange) async throws(AppStoreConnectError) {
        try write("updateVersion \(versionID) \(change.version) \(change.releaseType?.rawValue ?? "-") \(change.buildID ?? "-")")
    }

    func updateWhatsNew(_ localizationID: String, text: String) async throws(AppStoreConnectError) {
        try write("updateWhatsNew \(localizationID) \(text)")
    }

    func updateListing(_ localizationID: String, _ text: ListingText) async throws(AppStoreConnectError) {
        let fields = ListingText.Field.allCases.compactMap { field in text[field].map { "\(field.rawValue)=\($0)" } }
        try write("updateListing \(localizationID) \(fields.joined(separator: " "))")
    }

    func reviewDetail(of versionID: String) async throws(AppStoreConnectError) -> AppStoreReviewDetail? {
        state.withLock { $0.reviewDetails[versionID] }
    }

    func writeReviewDetail(_ detailID: String?, versionID: String, _ information: ReviewInformation) async throws(AppStoreConnectError) {
        var fields: [String] = []
        if let notes = information.notes { fields.append("notes=\(notes)") }
        if let required = information.demoAccountRequired { fields.append("demoAccountRequired=\(required)") }
        if let name = information.demoAccountName { fields.append("demoAccountName=\(name)") }
        try write("writeReviewDetail \(detailID ?? "new:\(versionID)") \(fields.joined(separator: " "))")
    }

    func screenshotSets(of localizationID: String) async throws(AppStoreConnectError) -> [AppStoreScreenshotSet] {
        state.withLock { $0.screenshotSets[localizationID] ?? [] }
    }

    func downloadScreenshot(_ url: URL) async throws(AppStoreConnectError) -> Data {
        guard let data = state.withLock({ $0.images[url] }) else { throw .refused(status: 404, detail: "画像が無い") }
        return data
    }

    func displayTypePlatforms() async throws(AppStoreConnectError) -> [String: AppStorePlatform] {
        state.withLock { $0.displayTypePlatforms }
    }

    func assetLibrary(of appID: String) async throws(AppStoreConnectError) -> String {
        "library-\(appID)"
    }

    func libraryImages(in libraryID: String, referenceName: String) async throws(AppStoreConnectError) -> [AppStoreLibraryImage] {
        let (images, failure) = state.withLock { ($0.libraryImages[referenceName] ?? [], $0.libraryFailure) }
        if let failure { throw failure }
        return images
    }

    func sendImage(
        to libraryID: String,
        fileName: String,
        referenceName: String,
        data: Data
    ) async throws(AppStoreConnectError) -> String {
        try write("sendImage \(fileName)")
        return state.withLock { state in
            let image = AppStoreLibraryImage(id: "image-\(fileName)", state: state.sentState)
            state.libraryImages[referenceName, default: []].append(image)
            return image.id
        }
    }

    func libraryImage(_ id: String) async throws(AppStoreConnectError) -> AppStoreLibraryImage {
        if let failure = state.withLock({ $0.sentImageFailure }) { throw failure }
        guard let image = state.withLock({ $0.libraryImages.values.flatMap(\.self).first { $0.id == id } }) else {
            throw .refused(status: 404, detail: "画像が無い")
        }
        return image
    }

    /// 参照名の画像の処理の様子を変える（Apple の処理が進んだ・失敗した）
    func setLibraryState(_ referenceName: String, _ newState: String, details: String? = nil) {
        state.withLock { state in
            state.libraryImages[referenceName] = (state.libraryImages[referenceName] ?? []).map {
                AppStoreLibraryImage(id: $0.id, state: newState, details: details)
            }
        }
    }

    func deleteImage(_ id: String) async throws(AppStoreConnectError) {
        try write("deleteImage \(id)")
    }

    func placeScreenshot(_ imageID: String, on localizationID: String, displayType: String) async throws(AppStoreConnectError) -> String {
        try write("placeScreenshot \(imageID) \(localizationID)")
        return state.withLock { state in
            // 同じ画像を言語ごとに置いても、配置の id は配置ごとに違う
            state.placementCount += 1
            let shot = AppStoreScreenshot(id: "placement-\(state.placementCount)", imageID: imageID, checksum: nil, imageURL: nil)
            var sets = state.screenshotSets[localizationID] ?? []
            if let index = sets.firstIndex(where: { $0.displayType == displayType }) {
                sets[index].screenshots.append(shot)
            } else {
                sets.append(AppStoreScreenshotSet(displayType: displayType, screenshots: [shot]))
            }
            state.screenshotSets[localizationID] = sets
            return shot.id
        }
    }

    func deletePlacement(_ id: String) async throws(AppStoreConnectError) {
        try write("deletePlacement \(id)")
        state.withLock { state in
            for (localization, sets) in state.screenshotSets {
                state.screenshotSets[localization] = sets.map { set in
                    AppStoreScreenshotSet(displayType: set.displayType, screenshots: set.screenshots.filter { $0.id != id })
                }
            }
        }
    }

    func orderScreenshots(on localizationID: String, displayType: String, ids: [String]) async throws(AppStoreConnectError) {
        try write("orderScreenshots \(localizationID) \(ids.joined(separator: ","))")
        state.withLock { state in
            state.screenshotSets[localizationID] = (state.screenshotSets[localizationID] ?? []).map { set in
                guard set.displayType == displayType else { return set }
                let ordered = ids.compactMap { id in set.screenshots.first { $0.id == id } }
                return AppStoreScreenshotSet(displayType: displayType, screenshots: ordered)
            }
        }
    }

    func reviewSubmissions(of appID: String, platform: AppStorePlatform) async throws(AppStoreConnectError) -> [AppStoreReviewSubmission] {
        state.withLock { $0.submissions.filter { $0.platform == platform } }
    }

    func createReviewSubmission(
        of appID: String,
        platform: AppStorePlatform
    ) async throws(AppStoreConnectError) -> AppStoreReviewSubmission {
        try write("createReviewSubmission \(platform.rawValue)")
        let created = AppStoreReviewSubmission(id: "s-\(platform.rawValue)", platform: platform, state: .readyForReview, versionID: nil)
        state.withLock { $0.submissions.append(created) }
        return created
    }

    func addToReviewSubmission(_ submissionID: String, versionID: String) async throws(AppStoreConnectError) {
        try write("addToReviewSubmission \(submissionID) \(versionID)")
        state.withLock { state in
            if let index = state.submissions.firstIndex(where: { $0.id == submissionID }) { state.submissions[index].versionID = versionID }
        }
    }

    func submitReviewSubmission(_ submissionID: String) async throws(AppStoreConnectError) {
        try write("submitReviewSubmission \(submissionID)")
        state.withLock { state in
            if let index = state.submissions.firstIndex(where: { $0.id == submissionID }) {
                state.submissions[index].state = .waitingForReview
            }
        }
    }

    func cancelReviewSubmission(_ submissionID: String) async throws(AppStoreConnectError) {
        try write("cancelReviewSubmission \(submissionID)")
    }

    func requestRelease(of versionID: String) async throws(AppStoreConnectError) {
        try write("requestRelease \(versionID)")
    }

    func deleteVersion(_ versionID: String) async throws(AppStoreConnectError) {
        try write("deleteVersion \(versionID)")
        state.withLock { $0.others.removeAll { $0.id == versionID } }
    }

    // MARK: - 準備

    func registeredBundleIDs(_ identifiers: [String]) async throws(AppStoreConnectError) -> [String] {
        let (registered, refusal) = state.withLock { ($0.bundleIDs, $0.bundleIDRefusal) }
        if let refusal { throw refusal }
        return identifiers.filter(registered.contains)
    }

    func registerBundleID(_ identifier: String, name: String, platform: BundleIDPlatform) async throws(AppStoreConnectError) {
        try write("registerBundleID \(identifier) \(platform.rawValue) \(name)")
        state.withLock { $0.bundleIDs.append(identifier) }
    }

    func setupState(of appID: String) async throws(AppStoreConnectError) -> AppStoreSetupState {
        state.withLock { $0.setup }
    }

    func setContentRights(_ value: ContentRightsDeclaration, of appID: String) async throws(AppStoreConnectError) {
        try write("setContentRights \(value.rawValue)")
        state.withLock { $0.setup.contentRights = value.appStoreConnectValue }
    }

    func setCategory(_ primary: String, subcategory: String?, appInfoID: String) async throws(AppStoreConnectError) {
        try write("setCategory \(appInfoID) \(primary) \(subcategory ?? "-")")
        state.withLock { $0.setup.primaryCategory = primary }
    }

    func setPrivacyPolicyURL(_ url: String, localizationID: String) async throws(AppStoreConnectError) {
        try write("setPrivacyPolicyURL \(localizationID) \(url)")
        state.withLock { state in
            if let index = state.setup.infoLocalizations.firstIndex(where: { $0.id == localizationID }) {
                state.setup.infoLocalizations[index].privacyPolicyUrl = url
            }
        }
    }

    func setFreePrice(of appID: String) async throws(AppStoreConnectError) {
        try write("setFreePrice")
        state.withLock { $0.setup.hasPrice = true }
    }

    func setAvailableEverywhere(of appID: String) async throws(AppStoreConnectError) {
        try write("setAvailableEverywhere")
        state.withLock { $0.setup.hasAvailability = true }
    }

    func versionSetupState(of versionID: String) async throws(AppStoreConnectError) -> AppStoreVersionSetupState {
        state.withLock { $0.versionSetups[versionID] ?? AppStoreVersionSetupState(missingReviewContact: ReviewContactField.allCases) }
    }

    func setCopyright(_ text: String, versionID: String) async throws(AppStoreConnectError) {
        try write("setCopyright \(versionID) \(text)")
        state.withLock { $0.versionSetups[versionID, default: .init()].copyright = text }
    }

    func allApps() async throws(AppStoreConnectError) -> [AppStoreApp] {
        state.withLock { $0.apps }
    }

    func reviewContact(of versionID: String) async throws(AppStoreConnectError) -> AppStoreReviewContact? {
        state.withLock { $0.reviewContacts[versionID] }
    }

    /// 書き込みの記録には、欄の名前だけを残す（値は残さない）
    func writeReviewContact(
        _ contact: ReviewContact,
        fields: [ReviewContactField],
        detailID: String?,
        versionID: String
    ) async throws(AppStoreConnectError) {
        try write("writeReviewContact \(versionID) \(fields.map(\.rawValue).joined(separator: ",")) \(detailID ?? "-")")
        state.withLock { state in
            let written = fields.filter { contact.values[$0] != nil }
            state.versionSetups[versionID, default: .init()].missingReviewContact.removeAll(where: written.contains)
            state.versionSetups[versionID]?.reviewDetailID = detailID ?? "detail-\(versionID)"
        }
    }

    func setVersionURLs(support: String?, marketing: String?, localizationID: String) async throws(AppStoreConnectError) {
        try write("setVersionURLs \(localizationID) \(support ?? "-") \(marketing ?? "-")")
        state.withLock { state in
            for (versionID, setup) in state.versionSetups {
                guard let index = setup.localizations.firstIndex(where: { $0.id == localizationID }) else { continue }
                if let support { state.versionSetups[versionID]?.localizations[index].supportUrl = support }
                if let marketing { state.versionSetups[versionID]?.localizations[index].marketingUrl = marketing }
            }
        }
    }
}
