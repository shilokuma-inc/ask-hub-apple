@testable import AskHub
import Foundation
import Testing

/// リポジトリの画面の一番上の「やること」と、app-kit を広げると PR を出す相手の数
@MainActor
struct RepositoryTodoTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let budget = DemoData.repositoryID("pocket-budget-ios")
    private let kaji = DemoData.repositoryID("kaji-share-ios")
    private let tsundoku = DemoData.repositoryID("tsundoku-ios")

    private func todos(_ repositoryID: TargetRepository.ID, in snapshot: ClientSnapshot) throws -> [RepositoryTodo] {
        let repository = try #require(snapshot.repository(repositoryID))
        return RepositoryTodo.items(for: repository, inbox: InboxBuilder.items(from: snapshot, now: now), snapshot: snapshot)
    }

    /// あなたの番のうちこのリポジトリのものを先に、ビルドの設定の残りを後に並べる。App Store の準備はあなたの番の行だけにする
    @Test
    func listsInboxItemsThenRepositorySettings() throws {
        let snapshot = DemoScenario.standard.snapshot(now: now)
        let items = try todos(budget, in: snapshot)
        #expect(items.map(\.title) == ["ゴールを確かめて開始する", "App Store の準備を終える", "ビルドの設定を入れる"])
        #expect(items.map(\.action) == [.route(.goal("budget-limit")), .route(.appStoreSetup(budget)), .buildSettings])
    }

    /// リリースを始める前（あなたの番に出さない）でも、App Store の準備の残りを出す
    @Test
    func showsAppStoreSetupBeforeFirstReleaseStarts() throws {
        var snapshot = DemoScenario.standard.snapshot(now: now)
        snapshot.submissions.removeAll { $0.repositoryID == budget }
        let item = try #require(try todos(budget, in: snapshot).first { $0.kind == .appStoreSetup })
        #expect(item.action == .route(.appStoreSetup(budget)))
        #expect(item.detail == "残り 9 個（カテゴリ・プライバシーポリシーの URL・価格 など）")
    }

    /// あなたの番でこのリポジトリの画面を開く行（準備）は、同じ画面の節へ送る行にし、保護を掛けていなければシートを開く行を足す。
    /// app-kit にまだ入れ替えていなくても、準備の PR の承認を待っていればその行で足りる
    @Test
    func replacesRepositoryRoutesWithActionsOnThisScreen() throws {
        let snapshot = DemoScenario.standard.snapshot(now: now)
        let items = try todos(kaji, in: snapshot)
        #expect(items.map(\.title) == [
            "App Store Connect でアプリを作る", "Discussions のカテゴリを作る", "ワークフローの直しを承認する", "ビルドの設定を入れる", "保護を掛ける"
        ])
        #expect(items.map(\.action) == [.route(.appStoreSetup(kaji)), .setup, .setup, .buildSettings, .protection])
    }

    /// app-kit のずれと、このリポジトリにまだ広げていない新しい版は、app-kit の画面を開く
    @Test
    func opensAppKitForDriftAndNewRelease() throws {
        let standard = try todos(tsundoku, in: DemoScenario.standard.snapshot(now: now)).filter { $0.kind == .appKit }
        #expect(standard.map(\.title) == ["app-kit のずれを直す"])
        let released = try todos(tsundoku, in: DemoScenario.appKitRelease.snapshot(now: now)).filter { $0.kind == .appKit }
        #expect(released.map(\.title) == ["app-kit のずれを直す", "app-kit v1.2.0 を広げる"])
        #expect(released.allSatisfy { $0.action == .route(.appKit) })
    }

    /// 広げると PR を出す相手は、入れ替え済みで古い版か、ずれのあるリポジトリとテンプレート（まだ入れ替えていないものは数えない）
    @Test
    func countsRolloutTargetsWithOlderVersions() throws {
        let standard = DemoScenario.standard.snapshot(now: now)
        let latest = try #require(standard.appKit?.latest)
        // 最新の版がどこにも入っていても、ずれのある相手（積読リスト）には同じ版を広げ直す PR を出す
        #expect(standard.appKitRolloutCount(latest) == 1)
        let released = DemoScenario.appKitRelease.snapshot(now: now)
        let release = try #require(released.appKit?.newRelease)
        // 習慣ログ・献立メモ・雨雲チェック・おこづかい帳・積読リストと、テンプレート 1 つ（家事シェアと visionOS のテンプレートはまだ入れ替えていない）
        #expect(released.appKitRolloutCount(release) == 6)
    }

    /// PR を出す相手の決まりは司令塔と同じ: major が違えば出さず、同じコミットでもずれがあれば出す
    @Test
    func rolloutTargetsFollowCommanderRules() throws {
        let release = AppKitOverview.Release(version: "v2.0.0", ref: "new", changes: nil, foundAt: now)
        #expect(!AppKitInstallation(version: "v1.9.0", ref: "old").receivesRollout(of: release))
        #expect(AppKitInstallation(version: "v2.0.0", ref: "new", drift: [".swiftlint.yml が無い"]).receivesRollout(of: release))
        #expect(!AppKitInstallation(version: "v2.0.0", ref: "new").receivesRollout(of: release))
        #expect(AppKitInstallation(version: "v2.0.0-beta", ref: "beta").receivesRollout(of: release))
        #expect(AppKitInstallation(version: nil, ref: "abc1234").receivesRollout(of: release))
    }
}
