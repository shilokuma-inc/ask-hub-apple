@testable import AskHub
import Testing

/// App Store のスクリーンショットの撮影モード（Discussion #605 の Q3）
@MainActor
struct ScreenshotDemoTests {
    @Test("-screenshot-demo が無ければ撮影モードにしない")
    func disabledWithoutDemoArgument() {
        #expect(!ScreenshotDemo.isEnabled(in: ["AskHub"]))
        // scene だけ渡しても撮影モードにはしない
        #expect(ScreenshotDemo.scene(in: ["AskHub", "-screenshot-scene", "status"]) == nil)
    }

    @Test("-screenshot-scene の値で撮る画面を選ぶ", arguments: ScreenshotDemo.Scene.allCases)
    func readsScene(scene: ScreenshotDemo.Scene) {
        let arguments = [
            "AskHub", "-screenshot-demo", "-screenshot-scene", scene.rawValue, "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"
        ]
        #expect(ScreenshotDemo.isEnabled(in: arguments))
        #expect(ScreenshotDemo.scene(in: arguments) == scene)
    }

    @Test("値が無い・知らない値のときは scene を nil にする（既定のタブで開く）")
    func unknownOrMissingSceneIsNil() {
        #expect(ScreenshotDemo.isEnabled(in: ["AskHub", "-screenshot-demo"]))
        #expect(ScreenshotDemo.scene(in: ["AskHub", "-screenshot-demo"]) == nil)
        #expect(ScreenshotDemo.scene(in: ["AskHub", "-screenshot-demo", "-screenshot-scene"]) == nil)
        #expect(ScreenshotDemo.scene(in: ["AskHub", "-screenshot-demo", "-screenshot-scene", "settings"]) == nil)
    }

    @Test("scene は App Store の上限（1 表示サイズにつき 10 枚）以内で、それぞれ別のタブを開く")
    func scenesOpenDistinctTabs() {
        let scenes = ScreenshotDemo.Scene.allCases
        #expect(scenes.count <= 10)
        #expect(Set(scenes.map(\.tab)).count == scenes.count)
    }
}
