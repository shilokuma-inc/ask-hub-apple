import AskHubProtocol
import Foundation

/// App Store Connect の版の枠（`docs/renewal/release.md` の「リリースを始めてから配信まで」の 2）。
/// リリースを始めた（`startRelease` を受け付けた）版に、プラットフォームごとに編集できる版を作り、release ブランチのビルドと What's New の下書きを入れておく
/// （審査に出すまで公開されない。スクショや説明文を先に直せる）。やめた（`abandonRelease`）版は、まだ審査に出していない枠を消す。
/// どれも、する前に今の様子を読み、途中で止まってもやり直せば同じになる
extension ReleaseWatch {
    /// 枠を作る・ビルドと What's New を入れる。変えたら記録を返し、変えることが無ければ nil
    func syncSlots(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard var slots = file.appStoreVersions else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        for platform in Self.slotPlatforms(versions, builds: file.builds) where !slots.contains(where: { $0.platform == platform }) {
            guard let slot = try await makeSlot(file, platform: platform, versions: versions, store: store, app: app) else { continue }
            slots.append(slot)
        }
        slots = try await attachBuilds(file, slots: slots, store: store, app: app)
        slots = try await writeWhatsNew(file, slots: slots, store: store)
        guard slots != file.appStoreVersions else { return nil }
        var file = file
        file.appStoreVersions = slots
        return file
    }

    /// 枠を作るプラットフォーム（アプリの版のあるプラットフォームと、release ブランチから上げたビルドのプラットフォーム。どちらも無ければ iOS）
    static func slotPlatforms(_ versions: [AppStoreVersionInfo], builds: [SubmissionFile.Build]) -> [AppStorePlatform] {
        var platforms: [AppStorePlatform] = []
        for platform in versions.map(\.platform) + builds.map(\.platform) where !platforms.contains(platform) {
            platforms.append(platform)
        }
        return platforms.isEmpty ? [.iOS] : platforms
    }

    /// 1 つのプラットフォームの枠。同じ番号の編集できる版があればそれを使い、無ければ作る。同じ番号の版がもう審査に出ていれば作らない（nil）。
    /// 別の番号の編集できる版があれば作らずに断る（App Store Connect の編集できる版はプラットフォームごとに 1 つ）。
    /// hotfix は、一時停止した進行中のリリースの編集できる版を、hotfix の版に付け替えて使う（審査中なら、取り下げを待つ）
    private func makeSlot(
        _ file: SubmissionFile,
        platform: AppStorePlatform,
        versions: [AppStoreVersionInfo],
        store: any AppStoreConnectSubmitting,
        app: AppStoreApp
    ) async throws -> SubmissionFile.VersionSlot? {
        let mine = versions.filter { $0.platform == platform && $0.versionString == file.version.rawValue }
        if let editable = mine.first(where: \.isEditable) {
            log("\(file.repo) の App Store Connect の \(platform.rawValue) \(file.version) の版を、リリースの枠にする")
            return .init(platform: platform, id: editable.id, at: context.timestamp)
        }
        // 手で審査に出した・配信した（審査の見張りが記録する）
        guard mine.isEmpty else { return nil }
        if let suspended = file.hotfix?.suspended {
            if let other = versions.first(where: { $0.platform == platform && $0.isEditable }) {
                let change = AppStoreVersionChange(version: file.version, releaseType: .afterApproval, buildID: nil)
                try await appStoreConnect { () throws(AppStoreConnectError) in try await store.updateVersion(other.id, change) }
                log("\(file.repo) の App Store Connect の \(platform.rawValue) \(other.versionString) の版を、hotfix \(file.version) に付け替えた")
                return .init(platform: platform, id: other.id, at: context.timestamp)
            }
            if versions.contains(where: { $0.platform == platform && $0.versionString == suspended.rawValue && $0.state.isUnderReview }) {
                throw ReleaseStepProblem("一時停止した \(suspended) の \(platform.rawValue) の審査の取り下げを待っている", needsHuman: false)
            }
        }
        if let other = versions.first(where: { $0.platform == platform && $0.isEditable }) {
            throw ReleaseStepProblem(
                "App Store Connect に、ほかの版（\(other.versionString)）の編集できる \(platform.rawValue) の版がある。"
                    + "そちらを App Store Connect で消すか審査に出し終えてから、このリリースをやめて始め直す",
                needsHuman: true
            )
        }
        let change = AppStoreVersionChange(version: file.version, releaseType: .afterApproval, buildID: nil)
        let created = try await appStoreConnect { () throws(AppStoreConnectError) in
            try await store.createVersion(of: app.id, platform: platform, change)
        }
        log("\(file.repo) の App Store Connect に \(platform.rawValue) \(file.version) の版を作った")
        return .init(platform: platform, id: created.id, at: context.timestamp)
    }

    /// release ブランチから上げたビルドを枠に選ぶ（変わったときだけ。配信の方式は送らず、人が App Store Connect で選んだものを残す）
    private func attachBuilds(
        _ file: SubmissionFile,
        slots: [SubmissionFile.VersionSlot],
        store: any AppStoreConnectSubmitting,
        app: AppStoreApp
    ) async throws -> [SubmissionFile.VersionSlot] {
        let wanted = slots.indices.filter { index in
            file.builds.contains { $0.platform == slots[index].platform && $0.build != slots[index].build }
        }
        guard !wanted.isEmpty else { return slots }
        let builds = try await appStoreConnect { () throws(AppStoreConnectError) in
            try await store.builds(of: app.id, version: file.version)
        }
        var slots = slots
        for index in wanted {
            let platform = slots[index].platform
            guard let number = file.builds.first(where: { $0.platform == platform })?.build,
                  let build = builds.first(where: { $0.platform == platform && $0.number == number }) else { continue }
            let change = AppStoreVersionChange(version: file.version, releaseType: nil, buildID: build.id)
            try await appStoreConnect { () throws(AppStoreConnectError) in try await store.updateVersion(slots[index].id, change) }
            log("\(file.repo) の App Store Connect の \(platform.rawValue) \(file.version) の版に、ビルド \(number) を選んだ")
            slots[index].build = number
        }
        return slots
    }

    /// What's New の下書きを、枠の各言語に 1 回だけ書く（後で人が App Store Connect で直した文を上書きしない。審査に出すときは人が確かめた文で上書きする）
    private func writeWhatsNew(
        _ file: SubmissionFile,
        slots: [SubmissionFile.VersionSlot],
        store: any AppStoreConnectSubmitting
    ) async throws -> [SubmissionFile.VersionSlot] {
        guard let drafts = file.whatsNew?.drafts, !drafts.isEmpty else { return slots }
        var slots = slots
        for index in slots.indices where !slots[index].whatsNew {
            let id = slots[index].id
            let localizations = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.localizations(of: id) }
            for draft in drafts {
                let localization = localizations.first { $0.locale == draft.locale }
                guard let localization, localization.whatsNew != draft.text else { continue }
                try await appStoreConnect { () throws(AppStoreConnectError) in
                    try await store.updateWhatsNew(localization.id, text: draft.text)
                }
            }
            log("\(file.repo) の App Store Connect の \(slots[index].platform.rawValue) \(file.version) の版に、What's New の下書きを書いた")
            slots[index].whatsNew = true
        }
        return slots
    }

    // MARK: - やめたリリースの枠を消す

    /// まだ審査に出していない枠を消す。審査に出ている・API で消せない枠は消さずに理由を書く（人に知らせる）
    func removeSlots(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard var slots = file.appStoreVersions, slots.contains(where: { $0.removal == nil }) else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        for index in slots.indices where slots[index].removal == nil {
            let slot = slots[index]
            // もう無い（人が消した・置き換わった）か、hotfix に付け替えた（ほかの版の番号になった）枠は消さない
            guard let info = versions.first(where: { $0.id == slot.id }), info.versionString == file.version.rawValue else {
                slots[index].removal = .deleted
                continue
            }
            guard info.isEditable else {
                slots[index].removal = .kept
                slots[index].removalNote = "審査に出ている・配信した版なので消さない（\(info.state.rawValue)）"
                continue
            }
            do {
                try await store.deleteVersion(slot.id)
                log("\(file.repo) のやめたリリースの、App Store Connect の \(slot.platform.rawValue) \(file.version) の版を消した")
                slots[index].removal = .deleted
            } catch .refused(404, _) {
                slots[index].removal = .deleted
            } catch let .refused(_, detail) {
                slots[index].removal = .kept
                slots[index].removalNote = "App Store Connect が消せないと答えた（\(detail)）。App Store Connect で確かめる"
            } catch {
                throw Self.problem(error)
            }
        }
        var file = file
        file.appStoreVersions = slots
        return file
    }
}

extension Blocker {
    /// やめたリリースの、消せなかった版の枠（人が App Store Connect で確かめる）
    static func keptSlots(on submission: SubmissionFile) -> [Blocker] {
        guard submission.end?.reason == .abandoned else { return [] }
        let scope = Scope.submission(submission.repo, submission.version)
        let base = "submission/\(submission.repo.rawValue)/\(submission.version.rawValue)"
        return (submission.appStoreVersions ?? []).filter { $0.removal == .kept }.map { slot in
            Blocker(key: "\(base)/slot/\(slot.platform.rawValue)/\(slot.id)/kept", scope: scope, reason: .slotKept(slot.platform))
        }
    }
}
