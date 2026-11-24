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

    /// 配信した版の知らせ（リリース文の確認・人が直す後作業）は、リポジトリの一覧からその版の画面を開く
    @Test
    func opensReleaseFromReleaseNotice() throws {
        let target = try #require(PushTarget(userInfo: userInfo(["repo": "shariverse/OshiKatsu-Countdown-iOS", "release": "1.1.0"])))
        let repo = try #require(RepositoryFullName(rawValue: "shariverse/OshiKatsu-Countdown-iOS"))
        #expect(target == .release(repo: repo, version: try #require(MarketingVersion(rawValue: "1.1.0"))))

        let navigator = AppNavigator()
        navigator.open(target)
        #expect(navigator.section == .repositories)
        // 画面のリポジトリの id は小文字にそろえる
        #expect(navigator.paths[.repositories] == [.release(repositoryID: "shariverse/oshikatsu-countdown-ios", version: "1.1.0")])
        // 版の形の違う値では開かない
        #expect(PushTarget(userInfo: userInfo(["repo": "shariverse/oshikatsu-countdown-ios", "release": "../1.1.0"])) == nil)
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

    /// いくつもの epic の実機確認のまとめは、あなたの番から実機確認の一覧を開く（まとめて答える・スワイプで流すを選べる）
    @Test
    func opensAllVerificationsFromVerificationDigest() throws {
        let target = try #require(PushTarget(userInfo: userInfo(["verification": "all"])))
        #expect(target == .verifications)

        let navigator = AppNavigator()
        navigator.section = .progress
        navigator.open(target)
        #expect(navigator.section == .inbox)
        #expect(navigator.selection == .verifications)
        #expect(navigator.paths[.inbox] == [.verifications])
        // 知らない値では開かない
        #expect(PushTarget(userInfo: userInfo(["verification": "today"])) == nil)
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
        // 開く先を持たない通知（古い司令塔の、いくつもの epic の実機確認のまとめ）は開かない
        #expect(PushTarget(userInfo: userInfo([:])) == nil)
    }
}
