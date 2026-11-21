import AskHubProtocol
import Foundation

/// 審査に出すときに、人が確かめたスクショを App Store Connect の App Asset Library に上げて置く（`docs/renewal/release.md` の「スクショ」）。
/// 差のある組の、人が「前のままにする」にしなかった差のある画面は撮った元の画像に、ほかの位置は配信中の版の画像（人が Before で見たもの）にする。
/// 置きたい画像の並びは配信中の版と撮ったものだけで決まり、画像は参照名（MD5）で探してから上げるので、途中で止まってもやり直せば同じになる
extension AppStoreSubmission {
    func writeScreenshots(of target: AppStoreVersionInfo, versions: [AppStoreVersionInfo]) async throws {
        guard let decision = request.screenshots, let captured = screenshots, captured.state == .captured,
              captured.commit == decision.commit else { return }
        let keep = Set(decision.keep)
        let changed = captured.sets.filter(\.isChanged)
        guard !changed.isEmpty else { return }
        let platforms = try await call { () throws(AppStoreConnectError) in try await store.displayTypePlatforms() }
        let sets = changed.filter { platforms[$0.displayType] == target.platform }
        guard !sets.isEmpty else { return }
        guard let originals else { throw ReleaseStepProblem("撮った元の画像の置き場所が分からない", needsHuman: true) }
        // 撮ったときに比べた相手（同じプラットフォームの配信中の版）。初めての版には無く、撮った画面はすべて新しい（前のままにする位置は置かない）
        let live = versions.first(where: { $0.platform == target.platform && $0.state == .readyForDistribution })
        let library = try await call { () throws(AppStoreConnectError) in try await store.assetLibrary(of: app.id) }
        var liveLocalizations: [AppStoreLocalization] = []
        if let live {
            liveLocalizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: live.id) }
        }
        let localizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: target.id) }
        // 書く前にすべての組を確かめる（後の組で止まって、先の組だけ書き換わることが無いように）
        var liveSets: [String: [AppStoreScreenshotSet]] = [:]
        var plans: [Plan] = []
        for set in sets {
            let changed = set.shots.filter(\.changed).map(\.index)
            // 差のある画面をすべて前のままにした組も、配信中の版の画像にそろえる（編集できる版が配信中の版と違うことがある）
            let accepted = Set(changed.filter { !keep.contains(.init(displayType: set.displayType, locale: set.locale, index: $0)) })
            guard let localization = localizations.first(where: { $0.locale == set.locale }) else {
                // 版に無い言語（設定に足したが App Store Connect にまだ無い）は、人がすべて前のままにした（載せない）なら飛ばす
                if accepted.isEmpty, liveLocalizations.allSatisfy({ $0.locale != set.locale }) { continue }
                let message = "\(target.platform.rawValue) の版に \(set.locale) の掲載文が無い。App Store Connect で言語を足すか、その言語の画面を載せない"
                throw ReleaseStepProblem(message, needsHuman: true)
            }
            if liveSets[set.locale] == nil, let source = liveLocalizations.first(where: { $0.locale == set.locale }) {
                liveSets[set.locale] = try await call { () throws(AppStoreConnectError) in try await store.screenshotSets(of: source.id) }
            }
            let plan = Plan(
                set: set,
                accepted: accepted,
                before: liveSets[set.locale]?.first { $0.displayType == set.displayType }?.screenshots ?? [],
                localization: localization
            )
            try plan.check(originals: originals)
            plans.append(plan)
        }
        for plan in plans {
            let images = try await images(of: plan, library: library, originals: originals)
            try await place(images, displayType: plan.set.displayType, on: plan.localization)
        }
    }

    /// 1 つの組の書き方
    struct Plan {
        var set: SubmissionFile.ScreenshotSet
        /// 撮った元の画像に替える位置（確かめた差のある画面）
        var accepted: Set<Int>
        /// 配信中の版の組（人が Before で見たもの）
        var before: [AppStoreScreenshot]
        /// 書く先の版の言語
        var localization: AppStoreLocalization

        /// 書けるかを確かめる。前のままにする位置の配信中の版の画像が、撮って比べたとき（人が Before で見たもの）から変わっていれば止める。
        /// 撮った元の画像が常時オンの Mac に無ければ止める
        func check(originals: URL) throws {
            for shot in set.shots {
                let target = StoreScreenshotTarget(displayType: set.displayType, locale: set.locale)
                if accepted.contains(shot.index) {
                    let original = StoreScreenshotRun.original(in: originals, target: target, index: shot.index)
                    guard FileManager.default.fileExists(atPath: original.path) else {
                        throw ReleaseStepProblem(
                            "撮った元の画像（\(target.key) の \(shot.index) 枚目）が常時オンの Mac に無い。リリースをやめて始め直すと撮り直す", needsHuman: true
                        )
                    }
                } else {
                    let live = shot.index <= before.count ? before[shot.index - 1] : nil
                    guard live?.imageURL?.absoluteString == shot.before else {
                        throw ReleaseStepProblem(
                            "配信中の版のスクショ（\(target.key) の \(shot.index) 枚目）が、撮って比べた後に変わった。リリースをやめて始め直すと撮り直す",
                            needsHuman: true
                        )
                    }
                }
            }
        }
    }

    /// 組の位置ごとに置きたい画像の id。前のままにした位置は配信中の版の画像、確かめた差のある画面は撮った元の画像（ライブラリに無ければ上げる）。
    /// 前回に無い位置を前のままにしたものは置かない
    private func images(of plan: Plan, library: String, originals: URL) async throws -> [String] {
        let set = plan.set
        var images: [String] = []
        for shot in set.shots {
            if plan.accepted.contains(shot.index) {
                let target = StoreScreenshotTarget(displayType: set.displayType, locale: set.locale)
                guard let data = try? Data(contentsOf: StoreScreenshotRun.original(in: originals, target: target, index: shot.index)) else {
                    throw ReleaseStepProblem(
                        "撮った元の画像（\(target.key) の \(shot.index) 枚目）を常時オンの Mac で読めない。リリースをやめて始め直すと撮り直す", needsHuman: true
                    )
                }
                let fileName = "\(set.displayType)-\(set.locale)-\(shot.index).png"
                images.append(try await libraryImage(data, fileName: fileName, library: library))
            } else if shot.index <= plan.before.count {
                images.append(plan.before[shot.index - 1].imageID)
            }
        }
        return images
    }

    /// ライブラリにある同じ画像（参照名の MD5）を使い、無ければ上げる。前の試行の、上げ終わらなかった・処理に失敗した同じ画像は消してから上げる
    private func libraryImage(_ data: Data, fileName: String, library: String) async throws -> String {
        let name = AppStoreScreenshot.referenceName(checksum: AppStoreScreenshot.checksum(of: data))
        let found = try await call { () throws(AppStoreConnectError) in try await store.libraryImages(in: library, referenceName: name) }
        if let ready = found.first(where: \.isPlaceable) { return ready.id }
        for stale in found { try? await store.deleteImage(stale.id) }
        return try await call { () throws(AppStoreConnectError) in
            try await store.uploadImage(to: library, fileName: fileName, referenceName: name, data: data)
        }
    }

    /// 版の言語の表示サイズの配置を、`images` の並びにする。同じ画像の配置は使い回し、余った配置を消してから足りない配置を作り
    /// （組の上限 10 枚でも詰まらない）、並べ直す。もう同じなら何もしない
    private func place(_ images: [String], displayType: String, on localization: AppStoreLocalization) async throws {
        let current = try await call { () throws(AppStoreConnectError) in try await store.screenshotSets(of: localization.id) }
            .first { $0.displayType == displayType }?.screenshots ?? []
        var unused = current
        var ids: [String?] = images.map { image in
            guard let index = unused.firstIndex(where: { $0.imageID == image }) else { return nil }
            return unused.remove(at: index).id
        }
        for old in unused {
            try await call { () throws(AppStoreConnectError) in try await store.deletePlacement(old.id) }
        }
        for (offset, image) in images.enumerated() where ids[offset] == nil {
            ids[offset] = try await call { () throws(AppStoreConnectError) in
                try await store.placeScreenshot(image, on: localization.id, displayType: displayType)
            }
        }
        let ordered = ids.compactMap(\.self)
        guard !ordered.isEmpty, ordered != current.map(\.id) else { return }
        try await call { () throws(AppStoreConnectError) in
            try await store.orderScreenshots(on: localization.id, displayType: displayType, ids: ordered)
        }
    }
}
