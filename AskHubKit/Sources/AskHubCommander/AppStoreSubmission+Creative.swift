import AskHubProtocol
import Foundation

/// 審査に出すときに、人が承認したクリエイティブアセットを、編集できる iOS の版の言語に置く（`docs/renewal/creative-assets.md` の「司令塔」）。
/// 画像はもうライブラリに上げてあり（承認の後の見回り）、参照名 `askhub-<MD5>` で探す。配置グループは、処理の済んだ画像の仕様（`specId`）を
/// 受け付ける配置グループを参照データから引く（決め打ちしない）。同じ画像の配置はそのまま、違う画像の配置は消してから作るので、
/// 途中で止まってもやり直せば同じになる。案に無い言語には置かず、今ある配置にも触らない
extension AppStoreSubmission {
    func writeCreative(of target: AppStoreVersionInfo) async throws {
        guard target.platform == .iOS, let choice = request.creative, let approved = creative, approved.revision == choice.revision else {
            return
        }
        guard let assets = store as? any AppStoreConnectCreative else {
            throw ReleaseStepProblem("クリエイティブアセットを置く道具が司令塔に無い", needsHuman: true)
        }
        let library = try await call { () throws(AppStoreConnectError) in try await store.assetLibrary(of: app.id) }
        let groups = try await call { () throws(AppStoreConnectError) in try await assets.creativePlacementGroups() }
        let localizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: target.id) }
        // 書く前にすべての画像を確かめる（後の画像で止まって、先の画像だけ置き換わることが無いように）
        var plans: [CreativePlan] = []
        for image in approved.images {
            guard let localization = localizations.first(where: { $0.locale == image.locale }) else { continue }
            let reference = AppStoreScreenshot.referenceName(checksum: image.md5)
            let found = try await call { () throws(AppStoreConnectError) in
                try await store.libraryImages(in: library, referenceName: reference)
            }
            guard let placeable = found.first(where: \.isPlaceable), let spec = placeable.specId else {
                // 消えた・処理中なら、承認の後の見回りが上げ直すのを待つ（人の問題にしない）
                let name = "\(image.locale) の \(image.kind.rawValue)"
                throw ReleaseStepProblem("承認したヘッダーと検索結果の画像（\(name)）がライブラリで置けない。上げ直しを待つ", needsHuman: false)
            }
            guard let group = groups[image.kind.placementType]?.first(where: { $0.specs.contains(spec) })?.id else {
                throw ReleaseStepProblem("\(image.kind.placementType) に、画像の仕様 \(spec) を置ける配置グループが無い", needsHuman: true)
            }
            plans.append(.init(localizationID: localization.id, kind: image.kind, imageID: placeable.id, group: group))
        }
        for plan in plans {
            let type = plan.kind.placementType
            let existing = try await call { () throws(AppStoreConnectError) in
                try await assets.creativePlacements(on: plan.localizationID, placementType: type)
            }
            if existing.contains(where: { $0.imageID == plan.imageID && $0.group == plan.group }) { continue }
            for old in existing where old.group == plan.group {
                try await call { () throws(AppStoreConnectError) in try await store.deletePlacement(old.id) }
            }
            _ = try await call { () throws(AppStoreConnectError) in
                try await assets.placeCreative(plan.imageID, on: plan.localizationID, placementType: type, group: plan.group)
            }
        }
    }

    /// 1 枚の置き方
    struct CreativePlan {
        var localizationID: String
        var kind: CreativeKind
        var imageID: String
        var group: String
    }
}
