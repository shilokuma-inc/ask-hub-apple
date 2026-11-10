@testable import AskHub
import AskHubProtocol
import Foundation
import Testing

/// 対象のリポジトリを持ち主（organization）ごとにまとめること（依頼のシートとリポジトリのタブ）と、持ち主のアバター
@MainActor
struct RepositoryGroupTests {
    private func repository(_ owner: String, _ name: String, appName: String? = nil) -> TargetRepository {
        TargetRepository(owner: owner, name: name, appName: appName ?? name, icon: .monogram)
    }

    /// 持ち主も中のリポジトリも名前順にする（大文字小文字を区別しない）
    @Test
    func groupsByOwnerInNameOrder() {
        let groups = RepositoryOwnerGroup.grouping([
            repository("shilokuma-inc", "prime-pick-ios"),
            repository("shariverse", "oshikatsu-countdown-ios"),
            repository("shilokuma-inc", "ask-hub-apple"),
            repository("tm-family", "family-ios"),
            repository("BeaconFun4", "beacon-ios"),
            repository("shariverse", "deki-roulette-ios")
        ])

        #expect(groups.map(\.owner) == ["BeaconFun4", "shariverse", "shilokuma-inc", "tm-family"])
        let names = groups.map { $0.repositories.map(\.name) }
        #expect(names == [
            ["beacon-ios"], ["deki-roulette-ios", "oshikatsu-countdown-ios"], ["ask-hub-apple", "prime-pick-ios"], ["family-ios"]
        ])
    }

    /// 同じ名前のリポジトリでも、持ち主が違えば別の見出しに入る
    @Test
    func keepsSameNameInDifferentOwnersApart() {
        let groups = RepositoryOwnerGroup.grouping([
            repository("shilokuma-inc", "countdown-ios"),
            repository("shariverse", "countdown-ios")
        ])

        #expect(groups.map(\.owner) == ["shariverse", "shilokuma-inc"])
        #expect(groups.map { $0.repositories.map(\.id) } == [["shariverse/countdown-ios"], ["shilokuma-inc/countdown-ios"]])
    }

    /// 大文字小文字だけ違う持ち主は 1 つの見出しにまとめ、先に並ぶリポジトリの書き方で出す（GitHub の login は大文字小文字を区別しない）
    @Test
    func mergesOwnersThatDifferOnlyInCase() {
        let groups = RepositoryOwnerGroup.grouping([repository("beaconfun4", "radar-ios"), repository("BeaconFun4", "beacon-ios")])

        #expect(groups.count == 1)
        #expect(groups.first?.owner == "BeaconFun4")
        #expect(groups.first?.repositories.map(\.name) == ["beacon-ios", "radar-ios"])
    }

    /// 中のリポジトリは、出すアプリ名の順に並べる
    @Test
    func sortsRepositoriesByAppName() {
        let groups = RepositoryOwnerGroup.grouping([
            repository("demo-studio", "a-ios", appName: "ルーレット"),
            repository("demo-studio", "b-ios", appName: "カウントダウン")
        ])

        #expect(groups.first?.repositories.map(\.appName) == ["カウントダウン", "ルーレット"])
    }

    /// 状態リポジトリのリポジトリの持ち主のアバターは、GitHub の持ち主の画像（トークンを付けずに読む public の URL）にする
    @Test
    func stateRepositoryUsesGitHubAvatarOfOwner() throws {
        let repo = try #require(RepositoryFullName(rawValue: "shariverse/deki-roulette-ios"))
        let url = try #require(URL(string: "https://github.com/shariverse.png?size=96"))

        let repository = StateSnapshotBuilder.repository(repo)

        #expect(repository.ownerAvatar == .image(url))
        #expect(RepositoryOwnerGroup.grouping([repository]).first?.avatar == .image(url))
    }

    /// デモのデータは 2 つの organization にまたがり、デモのリポジトリの id は持ち主ごとに引ける
    @Test
    func demoDataSpansTwoOwners() {
        let groups = RepositoryOwnerGroup.grouping(DemoData.repositories)

        #expect(groups.map(\.owner) == [DemoData.owner, DemoData.secondOwner])
        #expect(DemoData.repositoryID("tsundoku-ios") == "kurashi-apps/tsundoku-ios")
        #expect(DemoData.repositoryID("habit-ios") == "demo-studio/habit-ios")
        // デモの organization は架空なので、GitHub からは取らない
        let fetchesAvatar = groups.contains { group in
            if case .image = group.avatar { true } else { false }
        }
        #expect(!fetchesAvatar)
    }
}
