@testable import AskHub
import AskHubProtocol
import Foundation
import Testing

/// 判断のカードのスクショで撮る画面の一覧（`.askhub/screenshot-scenes.json`。repo.json の `build.screenshots.scenes`）。
/// ワーカーはこの起動引数でアプリを開いて撮り、画像は public の最終 PR に載るので、どの画面もデモのデータで開く
@MainActor
struct ScreenshotScenesTests {
    static let file = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".askhub/screenshot-scenes.json")

    @Test
    func everySceneOpensDemoData() throws {
        let scenes = try JSONDecoder().decode(ScreenshotScenesFile.self, from: Data(contentsOf: Self.file))
        #expect(scenes.problems.isEmpty)
        for scene in scenes.scenes {
            let arguments = Dictionary(
                stride(from: 0, to: scene.arguments.count - 1, by: 2).map { (scene.arguments[$0], scene.arguments[$0 + 1]) },
                uniquingKeysWith: { first, _ in first }
            )
            // 状態リポジトリにつながず、デモのデータで開く（実データを撮らない）
            #expect(arguments["-\(DemoScenario.preferenceKey)"].flatMap(DemoScenario.init(rawValue:)) != nil, "\(scene.id)")
            // 開く画面が読める値
            if let open = arguments["-\(DemoLaunch.openKey)"] {
                #expect(DemoLaunch.destination(from: open) != nil, "\(scene.id): \(open)")
            }
        }
    }
}
