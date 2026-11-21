import Foundation

// MARK: - 人の意図を当てる（App Store に載せる準備）

extension DemoClientService {
    /// 準備の操作。司令塔が受け付けて記録に写し、次の見回りで App Store Connect に送って確かめ直すのをまねる
    func applyAppStoreSetupIntent(_ intent: HumanIntent) {
        switch intent {
        case let .excludeFromAppStore(repositoryID, excluded):
            state.updateAppStoreSetup(repositoryID) { $0.isExcluded = excluded }

        case let .confirmAppStoreItem(repositoryID, item):
            state.updateAppStoreSetup(repositoryID) { setup in
                guard let index = setup.items.firstIndex(where: { $0.kind == item }) else { return }
                setup.items[index].confirmed = true
            }

        case let .registerBundleId(repositoryID, _, _):
            state.updateAppStoreSetup(repositoryID) { $0.bundleIDRequest = .init(sentAt: Date(), isDone: false) }
            schedule(after: 2) { snapshot in
                snapshot.updateAppStoreSetup(repositoryID) { setup in
                    setup.bundleIDRequest?.isDone = true
                    setup.mark(.bundleId, done: true)
                }
            }

        case let .applyAppStoreSettings(repositoryID, request):
            state.updateAppStoreSetup(repositoryID) { $0.settingsRequest = .init(sentAt: Date(), isDone: false) }
            schedule(after: 2) { snapshot in
                snapshot.updateAppStoreSetup(repositoryID) { setup in
                    setup.settingsRequest?.isDone = true
                    if request.copyReviewContact { setup.settingsRequest?.reviewContactFrom = "推し活カウントダウン" }
                    for kind in request.items { setup.mark(kind, done: true) }
                }
            }

        default:
            break
        }
    }
}

extension ClientSnapshot {
    mutating func updateAppStoreSetup(_ repositoryID: TargetRepository.ID, _ change: (inout AppStoreSetup) -> Void) {
        guard let index = appStoreSetups.firstIndex(where: { $0.repositoryID == repositoryID }) else {
            return
        }
        change(&appStoreSetups[index])
    }
}

extension AppStoreSetup {
    /// 項目の様子を書き換える（デモ）
    mutating func mark(_ kind: ItemKind, done: Bool) {
        guard let index = items.firstIndex(where: { $0.kind == kind }) else { return }
        items[index].state = done ? .done : .todo
        items[index].note = nil
    }
}
