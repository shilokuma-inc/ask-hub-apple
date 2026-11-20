import AskHubProtocol
import Foundation

/// 審査に出すときに、人が確かめたスクショを App Store Connect に上げる（`docs/renewal/release.md` の「スクショ」）。
/// 差のある画面のうち、人が「前のままにする」にしなかったものを撮った元の画像に替え、ほかの位置は今のスクショを残す。
/// 上げる前に今の組を読み、同じファイル（MD5）がもうあれば上げ直さないので、途中で止まってもやり直せば同じになる
extension AppStoreSubmission {
    func writeScreenshots(of target: AppStoreVersionInfo) async throws {
        guard let decision = request.screenshots, let captured = screenshots, captured.state == .captured,
              captured.commit == decision.commit else { return }
        let keep = Set(decision.keep)
        let sets = captured.sets.filter { Self.platform(of: $0.displayType) == target.platform && $0.isChanged }
        guard !sets.isEmpty else { return }
        guard let originals else { throw ReleaseStepProblem("撮った元の画像の置き場所が分からない", needsHuman: true) }
        let localizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: target.id) }
        for set in sets {
            let changed = set.shots.filter(\.changed).map(\.index)
            let accepted = Set(changed.filter { !keep.contains(.init(displayType: set.displayType, locale: set.locale, index: $0)) })
            // 差のある画面をすべて前のままにした組は触らない（後ろの位置を消すだけの組は、そのまま消す）
            guard !accepted.isEmpty || set.shots.allSatisfy({ !$0.changed }) else { continue }
            guard let localization = localizations.first(where: { $0.locale == set.locale }) else {
                let message = "\(target.platform.rawValue) の版に \(set.locale) の掲載文が無い。App Store Connect で言語を確かめる"
                throw ReleaseStepProblem(message, needsHuman: true)
            }
            try await replace(set, accepted: accepted, in: localization, originals: originals)
        }
    }

    private func replace(
        _ set: SubmissionFile.ScreenshotSet,
        accepted: Set<Int>,
        in localization: AppStoreLocalization,
        originals: URL
    ) async throws {
        let sets = try await call { () throws(AppStoreConnectError) in try await store.screenshotSets(of: localization.id) }
        let existing: AppStoreScreenshotSet
        if let found = sets.first(where: { $0.displayType == set.displayType }) {
            existing = found
        } else {
            existing = try await call { () throws(AppStoreConnectError) in
                try await store.createScreenshotSet(of: localization.id, displayType: set.displayType)
            }
        }
        var ids: [String] = []
        for shot in set.shots {
            if accepted.contains(shot.index) {
                let target = StoreScreenshotTarget(displayType: set.displayType, locale: set.locale)
                guard let data = try? Data(contentsOf: StoreScreenshotRun.original(in: originals, target: target, index: shot.index)) else {
                    throw ReleaseStepProblem(
                        "撮った元の画像（\(target.key) の \(shot.index) 枚目）が常時オンの Mac に無い。リリースをやめて始め直すと撮り直す", needsHuman: true
                    )
                }
                let checksum = AppStoreScreenshot.checksum(of: data)
                if let uploaded = existing.screenshots.first(where: { $0.checksum == checksum }) {
                    ids.append(uploaded.id)
                } else {
                    let name = "\(set.displayType)-\(set.locale)-\(shot.index).png"
                    ids.append(try await call { () throws(AppStoreConnectError) in
                        try await store.uploadScreenshot(to: existing.id, fileName: name, data: data)
                    })
                }
            } else if shot.index <= existing.screenshots.count {
                ids.append(existing.screenshots[shot.index - 1].id)
            }
        }
        for old in existing.screenshots where !ids.contains(old.id) {
            try await call { () throws(AppStoreConnectError) in try await store.deleteScreenshot(old.id) }
        }
        try await call { () throws(AppStoreConnectError) in try await store.orderScreenshots(of: existing.id, ids: ids) }
    }

    /// 表示サイズのプラットフォーム（iPhone・iPad は iOS、Mac は macOS、Vision Pro は visionOS、Apple TV は tvOS）
    static func platform(of displayType: String) -> AppStorePlatform? {
        if displayType.hasPrefix("APP_IPHONE") || displayType.hasPrefix("APP_IPAD") { return .iOS }
        if displayType == "APP_DESKTOP" { return .macOS }
        if displayType == "APP_APPLE_VISION_PRO" { return .visionOS }
        if displayType == "APP_APPLE_TV" { return .tvOS }
        return nil
    }
}
