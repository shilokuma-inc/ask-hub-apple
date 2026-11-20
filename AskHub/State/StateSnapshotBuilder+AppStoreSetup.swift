import AskHubProtocol
import Foundation

// MARK: - 新しいアプリを App Store に載せる準備

extension StateSnapshotBuilder {
    /// 準備の記録（リポジトリの順）。この端末が送って司令塔がまだ処理していない操作は、送った結果として先に出す
    /// （「終わった」を押した項目は終わり、出さないを押したリポジトリは出さない、書き込みは送っている途中）
    func appStoreSetups(index: inout StateIndex, overlaid: [IntentEnvelope]) -> [AppStoreSetup] {
        documents.appStoreSetups.map { file in
            var setup = Self.appStoreSetup(file)
            // 古い順に当てる（出さないを押してから戻したときは、戻したほうが残る）
            for envelope in overlaid.reversed() where envelope.repo == file.repo {
                Self.apply(envelope, to: &setup)
            }
            index.appStoreSetups[setup.repositoryID] = StateIndex.AppStoreSetupEntry(
                bundleIDs: setup.bundleIDs,
                hasApp: setup.app != nil,
                isActive: setup.isActive,
                isExcluded: setup.isExcluded,
                isWriting: setup.isWriting,
                confirmable: Set(setup.items.filter { !$0.isDone && $0.kind != .app }.map(\.kind))
            )
            return setup
        }
        .sorted { $0.repositoryID.localizedStandardCompare($1.repositoryID) == .orderedAscending }
    }

    static func appStoreSetup(_ file: AppStoreSetupFile) -> AppStoreSetup {
        AppStoreSetup(
            repositoryID: repository(file.repo).id,
            bundleIDs: file.bundleIds,
            mainBundleID: AppStoreSetupFile.mainBundleID(among: file.bundleIds),
            app: file.app.map { .init(id: $0.id, name: $0.name, bundleID: $0.bundleId, primaryLocale: $0.primaryLocale) },
            items: file.items.compactMap(item),
            bundleIDRequest: file.bundleIdRequest.map { request(at: $0.at, doneAt: $0.doneAt, failures: $0.failures) },
            settingsRequest: file.settingsRequest.map { request(at: $0.at, doneAt: $0.doneAt, failures: $0.failures) },
            isExcluded: file.isExcluded,
            releasedAt: file.releasedAt?.date,
            problem: file.problem.map { .init(message: $0.message, needsHuman: $0.needsHuman) },
            updatedAt: file.updatedAt.date
        )
    }

    private static func item(_ item: AppStoreSetupFile.Item) -> AppStoreSetup.Item? {
        guard let kind = AppStoreSetup.ItemKind(rawValue: item.id.rawValue) else { return nil }
        let state: AppStoreSetup.ItemState = switch item.state {
        case .todo: .todo
        case .done: .done
        case .unknown: .unknown
        }
        return .init(kind: kind, state: state, note: item.note, confirmed: item.confirmed != nil)
    }

    private static func request(at: Timestamp, doneAt: Timestamp?, failures: [AppStoreSetupFile.Failure]?) -> AppStoreSetup.WriteRequest {
        AppStoreSetup.WriteRequest(
            sentAt: at.date,
            isDone: doneAt != nil,
            failures: (failures ?? []).compactMap { failure in
                AppStoreSetup.ItemKind(rawValue: failure.item.rawValue).map { .init(item: $0, message: failure.message) }
            }
        )
    }

    /// 処理を待つ意図を、送った結果として当てる
    private static func apply(_ envelope: IntentEnvelope, to setup: inout AppStoreSetup) {
        switch envelope.kind {
        case ExcludeFromAppStoreIntent.kind:
            if let exclude = try? ExcludeFromAppStoreIntent(envelope: envelope) { setup.isExcluded = exclude.excluded }

        case ConfirmAppStoreItemIntent.kind:
            guard let confirm = try? ConfirmAppStoreItemIntent(envelope: envelope),
                  let index = setup.items.firstIndex(where: { $0.kind.rawValue == confirm.item.rawValue }) else { return }
            setup.items[index].confirmed = true

        case RegisterBundleIdIntent.kind:
            setup.bundleIDRequest = .init(sentAt: envelope.issuedAt.date, isDone: false)

        case ApplyAppStoreSettingsIntent.kind:
            setup.settingsRequest = .init(sentAt: envelope.issuedAt.date, isDone: false)

        default:
            break
        }
    }

    /// 準備の意図の呼び名。どれでもなければ nil
    static func appStoreSetupLabel(_ envelope: IntentEnvelope) -> String? {
        let name = envelope.repo?.name ?? ""
        switch envelope.kind {
        case RegisterBundleIdIntent.kind:
            return "Bundle ID の登録（\(envelope.string("identifier") ?? name)）"
        case ApplyAppStoreSettingsIntent.kind:
            return "App Store Connect に値を書く（\(name)）"
        case ConfirmAppStoreItemIntent.kind:
            let item = envelope.string("item").flatMap(AppStoreSetup.ItemKind.init(rawValue:))
            return "終わった（\(name) \(item?.title ?? "")）"
        case ExcludeFromAppStoreIntent.kind:
            guard case .bool(let excluded)? = envelope.payload?["excluded"] else { return nil }
            return excluded ? "App Store に出さない（\(name)）" : "App Store に出すに戻す（\(name)）"
        default:
            return nil
        }
    }
}
