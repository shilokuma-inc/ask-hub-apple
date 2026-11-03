@testable import AskHub
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
