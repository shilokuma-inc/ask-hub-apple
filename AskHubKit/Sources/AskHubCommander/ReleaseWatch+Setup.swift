import AskHubProtocol
import AskHubStateStore
import Foundation

/// 新しいアプリを App Store に載せる準備（`docs/renewal/release.md` の「新しいアプリを載せる」）。
/// App Store Connect にアプリが無い・配信中の版が無いリポジトリのチェックリストを、配信を見つけるのと同じ間隔（30 分ごと）に確かめて
/// `app-store.json` に書く。人が押した書き込み（Bundle ID の登録・決まった値）は、見回りのたびに送る
extension ReleaseWatch {
    // MARK: - 確かめる

    /// App Store Connect で確かめた結果
    struct SetupCheck: Sendable {
        var app: AppStoreSetupFile.App?
        var items: [AppStoreSetupFile.Item]
        /// 読めなかった理由（読めなかったときは、前の記録のアプリと項目を残す）
        var problem: AppStoreSetupFile.Problem?
    }

    /// 配信を見つけるときに読んだアプリと配信中の版から、準備の記録を書く。出さない・配信した記録は確かめない
    func checkSetup(_ repo: RepositoryFullName, found: (store: Int, app: AppStoreApp)?, live: Bool) async {
        let existing: AppStoreSetupFile?
        do {
            existing = try await context.read(AppStoreSetupFile.self, at: StatePath.appStoreSetup(repo))
        } catch {
            report("\(repo) の App Store の準備の記録を読めない（\(error)）。次に読むときにやり直す")
            return
        }
        if let existing, !existing.isActive { return }
        if live {
            // 初めての版を配信した。記録が無い（前から配信していた）アプリには作らない
            if existing != nil { await markReleased(repo) }
            return
        }
        let bundleIDs = bundleIdentifiers[repo] ?? []
        guard !bundleIDs.isEmpty else { return }
        let checked = if let found {
            await checkApp(repo, found: found)
        } else {
            SetupCheck(items: await checkWithoutApp(repo, bundleIDs: bundleIDs))
        }
        if existing == nil {
            await createSetup(repo, bundleIDs: bundleIDs, checked: checked)
        } else {
            await updateSetup(repo, bundleIDs: bundleIDs, checked: checked)
        }
    }

    private func markReleased(_ repo: RepositoryFullName) async {
        let now = context.timestamp
        await saveSetup(repo, message: "\(repo) の初めての版を配信した") { file in
            guard file.isActive else { return false }
            file.releasedAt = now
            return true
        }
    }

    /// 確かめた結果を前の記録に書く。様子が変わらなければ書かない
    private func updateSetup(_ repo: RepositoryFullName, bundleIDs: [String], checked: SetupCheck) async {
        let now = context.timestamp
        await saveSetup(repo, message: "\(repo) の App Store の準備を確かめた") { file in
            guard file.isActive else { return false }
            let before = file
            file.bundleIds = bundleIDs
            // 読めなかったときは、前に読んだアプリと項目を残す
            if let app = checked.app { file.app = app }
            if !checked.items.isEmpty { file.items = Self.merging(checked.items, into: file.items) }
            file.problem = checked.problem
            guard file != before else { return false }
            file.checkedAt = now
            return true
        }
    }

    /// 初めて確かめたリポジトリの記録を作る。読めなかったときは作らない（アプリがあるのに「アプリを作る」と出さないように）
    private func createSetup(_ repo: RepositoryFullName, bundleIDs: [String], checked: SetupCheck) async {
        guard checked.problem == nil else { return }
        let now = context.timestamp
        let file = AppStoreSetupFile(
            repo: repo,
            bundleIds: bundleIDs,
            app: checked.app,
            items: checked.items,
            checkedAt: now,
            createdAt: now,
            updatedAt: now
        )
        do {
            try await createSetup(file)
            log("\(repo) の App Store の準備を確かめた（残り \(file.pendingItems(firstRelease: true).count)）")
        } catch {
            report("\(repo) の App Store の準備の記録を作れない（\(error)）。次に読むときにやり直す")
        }
    }

    /// 新しく確かめた項目に、前の記録の人の「終わった」を残す。様子が変わらない項目は、前に確かめた時刻を残す（記録を書き直さない）
    static func merging(_ checked: [AppStoreSetupFile.Item], into previous: [AppStoreSetupFile.Item]) -> [AppStoreSetupFile.Item] {
        checked.map { item in
            guard let old = previous.first(where: { $0.id == item.id }) else { return item }
            var merged = item
            merged.confirmed = old.confirmed
            if old.state == item.state, old.note == item.note { merged.checkedAt = old.checkedAt }
            return merged
        }
    }

    /// アプリが無いとき: アプリ本体の Bundle ID が登録してあるかと、アプリの作成
    private func checkWithoutApp(_ repo: RepositoryFullName, bundleIDs: [String]) async -> [AppStoreSetupFile.Item] {
        let now = context.timestamp
        guard let main = AppStoreSetupFile.mainBundleID(among: bundleIDs) else {
            return [
                .init(id: .bundleId, state: .unknown, note: "アプリ本体の Bundle ID が見つからない（テストのターゲットのものだけ）", checkedAt: now),
                .init(id: .app, state: .todo, checkedAt: now)
            ]
        }
        var bundle = AppStoreSetupFile.Item(id: .bundleId, state: .unknown, checkedAt: now)
        var refused: AppStoreConnectError?
        for store in stores {
            do {
                if try await store.registeredBundleIDs([main]).contains(main) {
                    bundle.state = .done
                    break
                }
                bundle.state = .todo
            } catch {
                refused = error
            }
        }
        if bundle.state == .unknown, let refused {
            bundle.note = "鍵で Bundle ID を読めない（\(refused)）。Upload の Export でも登録される"
        } else if bundle.state == .todo {
            bundle.note = "\(main) がまだ登録されていない。登録するか、develop への push の Upload（Export）を待つ"
        }
        let app = AppStoreSetupFile.Item(
            id: .app,
            state: .todo,
            note: "App Store Connect の「アプリ」の「＋」で作る（Bundle ID と SKU は \(main)）",
            checkedAt: now
        )
        return [bundle, app]
    }

    /// アプリがあるとき: すべての項目。初めての版の項目は、版の枠があるときだけ
    private func checkApp(_ repo: RepositoryFullName, found: (store: Int, app: AppStoreApp)) async -> SetupCheck {
        let now = context.timestamp
        guard let slots = await firstReleaseSlots(repo) else {
            let message = "リリースの記録を読めないので、初めての版の項目を確かめられない"
            return SetupCheck(items: [], problem: .init(message: message, needsHuman: false, at: now))
        }
        // 枠が変わったら確かめ直すための印（読めなくても付ける。同じ枠で何度も読まない）
        checkedSlots[repo] = slots.map(\.id)
        let state: AppStoreSetupState
        let versions: [VersionSetup]
        do {
            state = try await stores[found.store].setupState(of: found.app.id)
            versions = try await versionSetups(slots, store: stores[found.store])
        } catch {
            report("\(repo) の App Store の準備を読めない（\(error)）。次に読むときにやり直す")
            let needsHuman = Self.problem(error).needsHuman
            let message = "App Store Connect の準備の様子を読めない（\(error)）"
            return SetupCheck(items: [], problem: .init(message: message, needsHuman: needsHuman, at: now))
        }
        let locale = state.primaryLocale.flatMap { LocalizedText.isLocale($0) ? $0 : nil }
        let app = AppStoreSetupFile.App(id: found.app.id, name: found.app.name, bundleId: found.app.bundleId, primaryLocale: locale)
        return SetupCheck(app: app, items: Self.items(from: state, at: now) + Self.versionItems(from: versions, at: now))
    }

    /// 読んだ様子から項目を作る
    static func items(from state: AppStoreSetupState, at now: Timestamp) -> [AppStoreSetupFile.Item] {
        typealias Item = AppStoreSetupFile.Item
        func item(_ kind: AppStoreSetupFile.ItemKind, _ done: Bool?, done doneNote: String? = nil, todo todoNote: String? = nil) -> Item {
            switch done {
            case true?: Item(id: kind, state: .done, note: doneNote, checkedAt: now)
            case false?: Item(id: kind, state: .todo, note: todoNote, checkedAt: now)
            case nil: Item(id: kind, state: .unknown, note: "App Store Connect で読めない", checkedAt: now)
            }
        }
        let missingPolicy = state.infoLocalizations.filter { ($0.privacyPolicyUrl ?? "").isEmpty }.map(\.locale)
        let policyDone: Bool? = state.appInfoID == nil ? nil : (!state.infoLocalizations.isEmpty && missingPolicy.isEmpty)
        let unanswered = state.unansweredAgeRatings
        return [
            Item(id: .bundleId, state: .done, checkedAt: now),
            Item(id: .app, state: .done, checkedAt: now),
            item(.contentRights, state.contentRights != nil, done: state.contentRights.map(Self.contentRightsLabel)),
            item(.category, state.appInfoID == nil ? nil : state.primaryCategory != nil, done: state.primaryCategory),
            item(.privacyPolicy, policyDone, todo: missingPolicy.isEmpty ? nil : "まだ書いていない言語: \(missingPolicy.joined(separator: "・"))"),
            item(.price, state.hasPrice),
            item(.availability, state.hasAvailability),
            item(.ageRating, unanswered.map(\.isEmpty), todo: unanswered.map { "答えていない質問が \($0.count) 個ある" }),
            Item(id: .appPrivacy, state: .unknown, note: "API が無い。App Store Connect の「App のプライバシー」で答えて公開する", checkedAt: now),
            Item(id: .digitalServicesAct, state: .unknown, note: "API が無い。App Store Connect の「App 情報」で DSA の申告をする", checkedAt: now)
        ]
    }

    static func contentRightsLabel(_ value: String) -> String {
        switch value {
        case ContentRightsDeclaration.doesNotUseThirdPartyContent.appStoreConnectValue: "第三者のコンテンツを使わない"
        case ContentRightsDeclaration.usesThirdPartyContent.appStoreConnectValue: "第三者のコンテンツを使う（権利がある）"
        default: value
        }
    }

    // MARK: - 人が押した書き込み

    /// 人が押した書き込みを送り、送り終えたら記録に書いて確かめ直す。送った後の記録を返す（記録が無ければ nil）
    func advanceSetup(_ repo: RepositoryFullName, settings: RepositoryFile) async -> AppStoreSetupFile? {
        guard let file = try? await context.readable(AppStoreSetupFile.self, at: StatePath.appStoreSetup(repo)) else { return nil }
        guard file.isActive, !stores.isEmpty else { return file }
        var sent = false
        if let request = file.bundleIdRequest, request.doneAt == nil {
            sent = await registerBundleID(repo, request: request) || sent
        }
        if let request = file.settingsRequest, request.doneAt == nil {
            sent = await applySettings(repo, request: request, settings: settings) || sent
        }
        guard sent else { return file }
        // 送った結果を、待たずに確かめ直す
        do {
            let found = try await app(of: repo, base: settings.build?.baseBranch)
            await checkSetup(repo, found: found, live: false)
        } catch {
            report("\(repo) の App Store の準備を確かめ直せない（\(error)）。次に読むときにやり直す")
        }
        return try? await context.readable(AppStoreSetupFile.self, at: StatePath.appStoreSetup(repo))
    }

    /// Bundle ID を登録する。アプリを見つけた鍵があればそれで、無ければ最初の鍵で送る。待てば直る失敗なら次の見回りでやり直す
    private func registerBundleID(_ repo: RepositoryFullName, request: AppStoreSetupFile.BundleIDRequest) async -> Bool {
        let store = stores[apps[repo]?.store ?? 0]
        var failures: [AppStoreSetupFile.Failure]?
        do {
            try await store.registerBundleID(request.identifier, name: Self.bundleIDName(request.identifier), platform: request.platform)
            log("\(repo) の Bundle ID \(request.identifier) を登録した")
        } catch .rateLimited, .unavailable {
            report("\(repo) の Bundle ID を登録できない（App Store Connect に届かない）。次の見回りでやり直す")
            return false
        } catch {
            report("\(repo) の Bundle ID \(request.identifier) を登録できない: \(error)")
            failures = [.init(item: .bundleId, message: Self.failureMessage(error))]
        }
        let result = failures
        await saveSetup(repo, message: "\(repo) の Bundle ID の登録を送った") { file in
            guard file.bundleIdRequest?.approval == request.approval, file.bundleIdRequest?.doneAt == nil else { return false }
            file.bundleIdRequest?.doneAt = self.context.timestamp
            file.bundleIdRequest?.failures = result
            return true
        }
        return true
    }

    /// 決まった値を書く。まだ決めていない項目だけ書く（人が App Store Connect で決めた値を上書きしない）。
    /// 様子を読めない（待てば直る）なら次の見回りでやり直し、項目ごとの失敗は理由を書いて終える
    private func applySettings(
        _ repo: RepositoryFullName,
        request: AppStoreSetupFile.SettingsRequest,
        settings repository: RepositoryFile
    ) async -> Bool {
        let found: (store: Int, app: AppStoreApp)
        let state: AppStoreSetupState
        var versions: [VersionSetup] = []
        var contactSource: ContactSource?
        do {
            guard let app = try await app(of: repo, base: repository.build?.baseBranch) else {
                await finishSettings(repo, request: request, failures: request.settings.items.map {
                    .init(item: $0, message: "App Store Connect にアプリが無い")
                })
                return true
            }
            found = app
            state = try await stores[app.store].setupState(of: app.app.id)
            if request.settings.items.contains(where: \.isVersionItem) {
                guard let slots = await firstReleaseSlots(repo) else { return false }
                versions = try await versionSetups(slots, store: stores[app.store])
            }
            if request.settings.reviewContact != nil, versions.contains(where: { !$0.state.missingReviewContact.isEmpty }) {
                contactSource = try await reviewContactSource(store: stores[app.store], excluding: app.app.id)
            }
        } catch {
            report("\(repo) の App Store Connect の値を書く前に読めない（\(error)）。次の見回りでやり直す")
            return false
        }
        let store = stores[found.store]
        var failures = await writeSettings(repo, request.settings, to: store, appID: found.app.id, state: state)
        let version = await writeVersionSettings(repo, request.settings, to: store, setups: versions, contactSource: contactSource)
        failures += version.failures
        await finishSettings(repo, request: request, failures: failures, reviewContactFrom: version.reviewContactFrom)
        return true
    }

    /// 決まった値のうち、まだ決めていない項目を書き、断られた項目を返す
    private func writeSettings(
        _ repo: RepositoryFullName,
        _ settings: AppStoreSettings,
        to store: any AppStoreConnecting,
        appID: String,
        state: AppStoreSetupState
    ) async -> [AppStoreSetupFile.Failure] {
        var failures: [AppStoreSetupFile.Failure] = []
        if let value = settings.contentRights, state.contentRights == nil {
            failures += await attempt(repo, .contentRights) { () async throws(AppStoreConnectError) in
                try await store.setContentRights(value, of: appID)
            }
        }
        if let primary = settings.primaryCategory, state.primaryCategory == nil {
            if let infoID = state.appInfoID {
                failures += await attempt(repo, .category) { () async throws(AppStoreConnectError) in
                    try await store.setCategory(primary, subcategory: settings.primarySubcategory, appInfoID: infoID)
                }
            } else {
                failures.append(.init(item: .category, message: "App 情報を読めない"))
            }
        }
        if let url = settings.privacyPolicyUrl {
            if state.infoLocalizations.isEmpty { failures.append(.init(item: .privacyPolicy, message: "App 情報の言語が無い")) }
            for localization in state.infoLocalizations where (localization.privacyPolicyUrl ?? "").isEmpty {
                failures += await attempt(repo, .privacyPolicy) { () async throws(AppStoreConnectError) in
                    try await store.setPrivacyPolicyURL(url, localizationID: localization.id)
                }
            }
        }
        if settings.price != nil, state.hasPrice != true {
            failures += await attempt(repo, .price) { () async throws(AppStoreConnectError) in try await store.setFreePrice(of: appID) }
        }
        if settings.availability != nil, state.hasAvailability != true {
            failures += await attempt(repo, .availability) { () async throws(AppStoreConnectError) in
                try await store.setAvailableEverywhere(of: appID)
            }
        }
        return failures
    }

    /// 1 つの書き込みを送る。断られたら理由を返す
    func attempt(
        _ repo: RepositoryFullName,
        _ item: AppStoreSetupFile.ItemKind,
        _ body: () async throws(AppStoreConnectError) -> Void
    ) async -> [AppStoreSetupFile.Failure] {
        do {
            try await body()
            log("\(repo) の App Store Connect に \(item.rawValue) を書いた")
            return []
        } catch {
            report("\(repo) の App Store Connect に \(item.rawValue) を書けない: \(error)")
            return [.init(item: item, message: Self.failureMessage(error))]
        }
    }

    private func finishSettings(
        _ repo: RepositoryFullName,
        request: AppStoreSetupFile.SettingsRequest,
        failures: [AppStoreSetupFile.Failure],
        reviewContactFrom: AppStoreSetupFile.SourceApp? = nil
    ) async {
        // 同じ項目の失敗は 1 つにまとめる（言語ごとのプライバシーポリシーの URL・サポート URL など）
        var merged: [AppStoreSetupFile.Failure] = []
        for failure in failures where !merged.contains(where: { $0.item == failure.item }) { merged.append(failure) }
        let result = merged
        await saveSetup(repo, message: "\(repo) の App Store Connect の値を書いた") { file in
            guard file.settingsRequest?.approval == request.approval, file.settingsRequest?.doneAt == nil else { return false }
            file.settingsRequest?.doneAt = self.context.timestamp
            file.settingsRequest?.failures = result.isEmpty ? nil : result
            file.settingsRequest?.reviewContactFrom = reviewContactFrom
            return true
        }
    }

    /// Certificates, Identifiers & Profiles に出す Bundle ID の名前（英数字と空白だけ。`.` と `-` は空白にする）
    static func bundleIDName(_ identifier: String) -> String {
        "AskHub " + identifier.map { $0 == "." || $0 == "-" ? " " : $0 }.map(String.init).joined()
    }

    /// 記録に書く理由（500 文字まで）
    static func failureMessage(_ error: AppStoreConnectError) -> String {
        let text = "\(error)"
        let limit = AppStoreSetupFile.Item.noteLimit
        return text.unicodeScalars.count > limit ? String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit - 1))) + "…" : text
    }

    // MARK: - 書く

    /// 記録を書き換える。書けなければログに出し、次の見回りでやり直す
    private func saveSetup(
        _ repo: RepositoryFullName,
        message: String,
        _ change: @escaping @Sendable (inout AppStoreSetupFile) -> Bool
    ) async {
        do {
            try await updateSetup(repo, message: message, change)
        } catch {
            report("\(repo) の App Store の準備の記録を書けない（\(error)）。次の見回りでやり直す")
        }
    }

    nonisolated private func createSetup(_ file: AppStoreSetupFile) async throws(CommanderError) {
        let path = StatePath.appStoreSetup(file.repo)
        try await context.writingResult { () throws(CommanderError) in
            do throws(StateFileStore.Failure) {
                try await context.files.create(file, at: path, message: "\(file.repo) の App Store の準備を確かめた")
            } catch {
                throw .files(error)
            }
        }
    }

    nonisolated private func updateSetup(
        _ repo: RepositoryFullName,
        message: String,
        _ change: @escaping @Sendable (inout AppStoreSetupFile) -> Bool
    ) async throws(CommanderError) {
        let path = StatePath.appStoreSetup(repo)
        let now = context.timestamp
        try await context.writingResult { () throws(CommanderError) in
            do throws(StateFileStore.Failure) {
                _ = try await context.files.update(AppStoreSetupFile.self, at: path, message: message) { file in
                    guard change(&file) else { return false }
                    file.updatedAt = now
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
    }
}

extension Blocker {
    /// 準備の記録から、人を待っているもの（アプリを作る・初めての版の残り・書き込みを断られた・人が直す問題）を拾う。
    /// `firstRelease` は、配信中の版が無いアプリで始めたリリースの版（無ければ nil）
    static func waiting(on setup: AppStoreSetupFile, firstRelease: MarketingVersion?) -> [Blocker] {
        guard setup.isActive else { return [] }
        let scope = Scope.appStore(setup.repo)
        let base = "appStore/\(setup.repo.rawValue)"
        var blockers: [Blocker] = []
        let forApp = setup.pendingItems(firstRelease: false)
        if setup.app == nil, !forApp.isEmpty {
            blockers.append(Blocker(key: "\(base)/app", scope: scope, reason: .appStoreApp))
        }
        if let firstRelease, setup.app != nil {
            let remaining = setup.pendingItems(firstRelease: true).count
            if remaining > 0 {
                let key = "\(base)/firstRelease/\(firstRelease.rawValue)"
                blockers.append(Blocker(key: key, scope: scope, reason: .appStoreFirstRelease(remaining: remaining)))
            }
        }
        for request in [setup.bundleIdRequest.map { ($0.doneAt, $0.failures) }, setup.settingsRequest.map { ($0.doneAt, $0.failures) }] {
            guard let (doneAt, failures) = request, let doneAt, let failures, !failures.isEmpty else { continue }
            let key = "\(base)/refused/\(doneAt.rawValue)/\(failures.map(\.item.rawValue).joined(separator: ","))"
            blockers.append(Blocker(key: key, scope: scope, reason: .appStoreRefused(failures.map(\.item))))
        }
        if let problem = setup.problem, problem.needsHuman {
            blockers.append(Blocker(key: "\(base)/problem/\(problem.at.rawValue)", scope: scope, reason: .appStoreProblem))
        }
        return blockers
    }
}
