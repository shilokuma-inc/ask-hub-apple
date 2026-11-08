@testable import AskHub
import AskHubProtocol
import Foundation
import Testing

/// 通知の中身の `askhub`（司令塔の APNsSender が入れる）から、開く画面を決めること
@MainActor
struct PushTargetTests {
    private let epic = "01JC4Y6Z8Q0000000000000000"

    /// APNs の通知の userInfo の形（`aps` と並んで `askhub` がある）
    private func userInfo(_ askhub: [String: String]) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "prime-pick-ios", "body": "質問 2 件が回答を待っています"]], "askhub": askhub]
    }

    /// epic の出来事は、進行中の一覧からその epic の画面を開く
    @Test
    func opensEpicFromEpicNotice() throws {
        let target = try #require(PushTarget(userInfo: userInfo(["repo": "shilokuma-inc/prime-pick-ios", "epic": epic])))
        #expect(target == .epic(repo: RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!, epic: ULID(rawValue: epic)!))

        let navigator = AppNavigator()
        navigator.open(target)
        #expect(navigator.section == .progress)
        #expect(navigator.selection == .epic(epic))
        #expect(navigator.paths[.progress] == [.epic(epic)])
    }

    /// Mac がオフラインの知らせは、Mac の一覧からその Mac の画面を開く
    @Test
    func opensMacFromMacNotice() throws {
        let target = try #require(PushTarget(userInfo: userInfo(["mac": "macbook-a"])))
        #expect(target == .mac(MacName(rawValue: "macbook-a")!))

        let navigator = AppNavigator()
        navigator.section = .inbox
        navigator.open(target)
        #expect(navigator.section == .macs)
        #expect(navigator.selection == .mac("macbook-a"))
    }

    /// 形の違う値や、`askhub` の無い通知では、どこも開かない
    @Test
    func ignoresMalformedTargets() {
        #expect(PushTarget(userInfo: ["aps": ["alert": "x"]]) == nil)
        #expect(PushTarget(userInfo: ["askhub": "shilokuma-inc/prime-pick-ios"]) == nil)
        #expect(PushTarget(userInfo: userInfo(["repo": "shilokuma-inc/prime-pick-ios", "epic": "../keys/1"])) == nil)
        #expect(PushTarget(userInfo: userInfo(["repo": "../..", "epic": epic])) == nil)
        #expect(PushTarget(userInfo: userInfo(["mac": "../macs/macbook-a"])) == nil)
        // epic の id だけで repo が無いものは開かない
        #expect(PushTarget(userInfo: userInfo(["epic": epic])) == nil)
    }
}
