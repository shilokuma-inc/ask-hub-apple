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
            // 時計を止め、Before と After を別の時刻に撮っても時刻の文がそろう
            #expect(arguments["-\(DemoScenario.clockKey)"].flatMap { try? Date($0, strategy: .iso8601) } != nil, "\(scene.id)")
            // 開く画面が読める値で、その場面のデモのデータにある（無い epic を開くと「見つかりません」を撮ってしまう）
            let scenario = arguments["-\(DemoScenario.preferenceKey)"].flatMap(DemoScenario.init)
            if let open = arguments["-\(DemoLaunch.openKey)"], let scenario {
                let destination = DemoLaunch.destination(from: open)
                #expect(destination != nil, "\(scene.id): \(open)")
                if let route = destination?.route {
                    #expect(Self.problem(of: route, in: scenario.snapshot(now: Date())) == nil, "\(scene.id): \(open)")
                }
            }
        }
    }

    /// 行き先がデモのデータに無いわけ。あれば nil でない
    static func problem(of route: AppRoute, in snapshot: ClientSnapshot) -> String? {
        switch route {
        case .epic(let id), .deck(.questions(let id)), .deck(.verifications(let id)), .humanTask(let id, _):
            return snapshot.epic(id) == nil ? "epic \(id) が無い" : nil
        case .goal(let id):
            return snapshot.epic(id)?.goal == nil ? "epic \(id) にゴールが無い" : nil
        case .finalReview(let id), .deck(.decisions(let id)):
            return snapshot.epic(id)?.finalReview == nil ? "epic \(id) に最終 PR が無い" : nil
        case .mac(let id), .cleanup(let id):
            return snapshot.macs.contains { $0.id == id } ? nil : "Mac \(id) が無い"
        case .repository(let id):
            return snapshot.repositories.contains { $0.id == id } ? nil : "リポジトリ \(id) が無い"
        case .deck(.all):
            return nil
        case .finishedEpics:
            return snapshot.epics.contains { !$0.isActive } ? nil : "終わった epic が無い"
        }
    }
}
