@testable import AskHub
import Foundation
import Testing

/// UI テストと撮影の起動引数（開く画面とスワイプの途中の状態）
@MainActor
struct DemoLaunchTests {
    /// 開く画面を読む
    @Test
    func parsesDestinations() {
        #expect(DemoLaunch.destination(from: "section:macs")?.section == .macs)
        #expect(DemoLaunch.destination(from: "deck:all")?.route == .deck(.all))
        #expect(DemoLaunch.destination(from: "deck:questions:recipe-weekly")?.route == .deck(.questions("recipe-weekly")))
        #expect(DemoLaunch.destination(from: "epic:rain-draft")?.route == .epic("rain-draft"))
        let human = DemoLaunch.destination(from: "human:rain-draft:ht-app-group")
        #expect(human?.route == .humanTask(epicID: "rain-draft", taskID: "ht-app-group"))
    }

    /// 読めない値は無視する
    @Test
    func ignoresUnknownValues() {
        #expect(DemoLaunch.destination(from: "unknown:x") == nil)
        #expect(DemoLaunch.destination(from: "deck:questions") == nil)
        #expect(DemoLaunch.destination(from: "section:nothing") == nil)
    }
}

/// App Store のスクショの撮影モード（Release でも動く）
@MainActor
struct ScreenshotDemoTests {
    /// 撮影モードの起動引数から撮る画面を読む
    @Test
    func readsSceneFromArguments() {
        #expect(ScreenshotDemo.scene(in: ["-screenshot-demo", "-screenshot-scene", "request"]) == .request)
        #expect(ScreenshotDemo.scene(in: ["-screenshot-scene", "request"]) == nil)
        #expect(ScreenshotDemo.scene(in: ["-screenshot-demo", "-screenshot-scene", "unknown"]) == nil)
    }

    /// 撮る画面は、どれもデモのデータにある epic を開く
    @Test
    func everySceneOpensDemoData() {
        let snapshot = DemoScenario.standard.snapshot(now: Date(timeIntervalSince1970: 1_800_000_000))
        for scene in ScreenshotDemo.Scene.allCases {
            switch scene.route {
            case .finalReview(let id):
                #expect(snapshot.epic(id)?.finalReview != nil)

            case .deck(.verifications(let id)):
                // 実機確認のカードは、TestFlight で確かめられる項目があるときだけ流れる
                let hasReadyItems = snapshot.epic(id)?.finalReview?.verifications.contains(where: \.isReady) ?? false
                #expect(hasReadyItems)

            case .deck(.all):
                // まとめて判断する画面は、カードが無いと空の表示が写る
                #expect(!DeckBuilder.cards(from: snapshot, scope: .all).isEmpty)

            case nil:
                break

            default:
                Issue.record("想定していない画面: \(scene)")
            }
        }
    }

    /// 撮る画面は、その画面のタブを開く（画面を開かない場面は、タブで撮るものが決まる）
    @Test
    func everySceneOpensItsTab() {
        let sections = Dictionary(uniqueKeysWithValues: ScreenshotDemo.Scene.allCases.map { ($0, $0.section) })
        #expect(sections == [.action: .inbox, .request: .inbox, .decisions: .inbox, .verification: .inbox, .status: .progress])
    }

    /// 起動のときは、撮る画面のタブを選び、画面があればそのタブで開く。撮影モードでなければ何も変えない
    @Test
    func openInitialScreenSelectsTabAndRoute() {
        for scene in ScreenshotDemo.Scene.allCases {
            let navigator = AppNavigator()
            ScreenshotDemo.openInitialScreen(scene, in: navigator)
            #expect(navigator.section == scene.section)
            #expect(navigator.paths[scene.section] == scene.route.map { [$0] })
        }
        let untouched = AppNavigator()
        ScreenshotDemo.openInitialScreen(nil, in: untouched)
        #expect(untouched.section == .inbox)
        #expect(untouched.paths.isEmpty)
    }
}
