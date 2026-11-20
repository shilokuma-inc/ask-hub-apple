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
    }

    let keyID = "ABCDE12345"
    let state = OSAllocatedUnfairLock(initialState: State())

    func apps(bundleIDs: [String]) async throws(AppStoreConnectError) -> [AppStoreApp] {
        state.withLock { $0.apps.filter { bundleIDs.contains($0.bundleId) } }
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
}
