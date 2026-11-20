import AskHubProtocol
import AskHubStateStore
import Foundation

/// 新しいアプリを App Store に載せる準備のうち、初めての版の項目（サポート URL・著作権表示・App Review の連絡先）。
/// 初めての版のリリースを始めて、App Store Connect に版の枠（`submissions/<版>.json` の `appStoreVersions`）があるときだけ、
/// 枠ごとに読んで項目にする（`docs/renewal/release.md` の「新しいアプリを載せる」）
extension ReleaseWatch {
    /// 1 つの版の枠と、App Store Connect で読んだその様子
    struct VersionSetup: Sendable {
        var slot: SubmissionFile.VersionSlot
        var state: AppStoreVersionSetupState
    }

    /// 終わっていないリリースの、まだ消していない版の枠。リリースを始めていなければ空、記録を読めなければ nil
    func firstReleaseSlots(_ repo: RepositoryFullName) async -> [SubmissionFile.VersionSlot]? {
        do {
            let entries = try await context.store.list(StatePath.submissions(repo)) ?? []
            var submissions: [SubmissionFile] = []
            for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
                guard let version = MarketingVersion(rawValue: String(entry.name.dropLast(".json".count))),
                      let file = try await context.readable(SubmissionFile.self, at: StatePath.submission(repo, version)) else { continue }
                submissions.append(file)
            }
            return Self.openSlots(submissions)
        } catch {
            report("\(repo) のリリースの記録を読めない（\(error)）。初めての版の項目は次に確かめる")
            return nil
        }
    }

    /// 終わっていないリリースの、まだ消していない版の枠
    static func openSlots(_ submissions: [SubmissionFile]) -> [SubmissionFile.VersionSlot] {
        submissions.filter { !$0.isEnded }.flatMap { ($0.appStoreVersions ?? []).filter { $0.removal == nil } }
    }

    /// 枠ごとに、版の項目の様子を読む
    func versionSetups(
        _ slots: [SubmissionFile.VersionSlot],
        store: any AppStoreConnecting
    ) async throws(AppStoreConnectError) -> [VersionSetup] {
        var setups: [VersionSetup] = []
        for slot in slots {
            setups.append(VersionSetup(slot: slot, state: try await store.versionSetupState(of: slot.id)))
        }
        return setups
    }

    /// 版の枠ごとの様子から、版の項目を作る（枠が無ければ持たない）。枠が複数あれば、すべての枠でそろったら終わり
    static func versionItems(from setups: [VersionSetup], at now: Timestamp) -> [AppStoreSetupFile.Item] {
        guard !setups.isEmpty else { return [] }
        typealias Item = AppStoreSetupFile.Item
        // 枠が 2 つ以上なら、どの枠のことかを前に付ける
        let prefix: (VersionSetup) -> String = setups.count > 1 ? { "\($0.slot.platform.rawValue) の " } : { _ in "" }

        let withoutLanguage = setups.filter { $0.state.localizations.isEmpty }
        let missingSupport = setups.flatMap { setup in
            setup.state.localizations.filter { $0.supportUrl == nil }.map { prefix(setup) + $0.locale }
        }
        let support: Item = if !withoutLanguage.isEmpty {
            Item(id: .supportUrl, state: .todo, note: "版に言語が無い（App Store Connect の版のページで言語を足す）", checkedAt: now)
        } else if !missingSupport.isEmpty {
            Item(id: .supportUrl, state: .todo, note: limited("まだ書いていない言語: \(missingSupport.joined(separator: "・"))"), checkedAt: now)
        } else {
            Item(id: .supportUrl, state: .done, note: same(setups.flatMap(\.state.localizations).compactMap(\.supportUrl)), checkedAt: now)
        }

        let missingCopyright = setups.filter { $0.state.copyright == nil }.map(\.slot.platform.rawValue)
        let copyright: Item = if missingCopyright.isEmpty {
            Item(id: .copyright, state: .done, note: same(setups.compactMap(\.state.copyright)), checkedAt: now)
        } else {
            Item(
                id: .copyright,
                state: .todo,
                note: setups.count > 1 ? "まだ書いていない版: \(missingCopyright.joined(separator: "・"))" : nil,
                checkedAt: now
            )
        }

        // 連絡先は、入れていない欄の名前だけを書く（入れた値は記録に書かない）
        let missingContact = setups.filter { !$0.state.missingReviewContact.isEmpty }.map { setup in
            prefix(setup) + setup.state.missingReviewContact.map(\.label).joined(separator: "・")
        }
        let contact = Item(
            id: .reviewContact,
            state: missingContact.isEmpty ? .done : .todo,
            note: missingContact.isEmpty ? nil : limited("まだ入れていない欄: \(missingContact.joined(separator: "、"))"),
            checkedAt: now
        )
        return [support, copyright, contact]
    }

    /// すべて同じ値なら、その値（項目の補足に今の値として出す）
    private static func same(_ values: [String]) -> String? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return limited(first)
    }

    /// 項目の補足の長さの上限に切る
    static func limited(_ text: String) -> String {
        let limit = AppStoreSetupFile.Item.noteLimit
        return text.unicodeScalars.count > limit ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit - 1))) + "…" : text
    }

    // MARK: - 書く

    /// 初めての版の決まった値（サポート URL・マーケティング URL・著作権表示）のうち、まだ書いていない言語・版に書き、断られた項目を返す。
    /// マーケティング URL は任意で項目を持たないので、断られたらサポート URL の項目に書く
    func writeVersionSettings(
        _ repo: RepositoryFullName,
        _ settings: AppStoreSettings,
        to store: any AppStoreConnecting,
        setups: [VersionSetup]
    ) async -> [AppStoreSetupFile.Failure] {
        let wantsURLs = settings.supportUrl != nil
        guard wantsURLs || settings.copyright != nil else { return [] }
        guard !setups.isEmpty else {
            let message = "初めての版のリリースを始めていない（App Store Connect に版の枠が無い）"
            return settings.items.filter(\.isVersionItem).map { .init(item: $0, message: message) }
        }
        var failures: [AppStoreSetupFile.Failure] = []
        for setup in setups {
            if let text = settings.copyright, setup.state.copyright == nil {
                failures += await attempt(repo, .copyright) { () async throws(AppStoreConnectError) in
                    try await store.setCopyright(text, versionID: setup.slot.id)
                }
            }
            guard wantsURLs else { continue }
            if setup.state.localizations.isEmpty {
                failures.append(.init(item: .supportUrl, message: "\(setup.slot.platform.rawValue) の版に言語が無い"))
            }
            for localization in setup.state.localizations {
                let support = localization.supportUrl == nil ? settings.supportUrl : nil
                let marketing = localization.marketingUrl == nil ? settings.marketingUrl : nil
                guard support != nil || marketing != nil else { continue }
                failures += await attempt(repo, .supportUrl) { () async throws(AppStoreConnectError) in
                    try await store.setVersionURLs(support: support, marketing: marketing, localizationID: localization.id)
                }
            }
        }
        return failures
    }

    // MARK: - 枠が変わったら確かめ直す

    /// 版の枠が、前に版の項目を確かめたときから変わった（リリースを始めて枠を作った・やめて枠を消した）なら、30 分を待たずに確かめ直す。
    /// 確かめ直しても読めなければ、次の 30 分ごとの確かめに任せる（同じ枠で何度も読まない）
    func recheckSetupIfSlotsChanged(
        _ repo: RepositoryFullName,
        setup: AppStoreSetupFile,
        submissions: [SubmissionFile],
        settings: RepositoryFile
    ) async -> AppStoreSetupFile? {
        guard setup.isActive, setup.app != nil, !stores.isEmpty, let checked = checkedSlots[repo] else { return nil }
        let slots = Self.openSlots(submissions).map(\.id)
        guard Set(slots) != Set(checked) else { return nil }
        do {
            let found = try await app(of: repo, base: settings.build?.baseBranch)
            await checkSetup(repo, found: found, live: false)
        } catch {
            report("\(repo) の初めての版の項目を確かめ直せない（\(error)）。次に読むときにやり直す")
        }
        checkedSlots[repo] = slots
        return try? await context.readable(AppStoreSetupFile.self, at: StatePath.appStoreSetup(repo))
    }
}
