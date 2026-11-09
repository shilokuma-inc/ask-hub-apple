import AskHubProtocol
import Foundation
import Testing

/// 判断のカードのスクショの撮り方（`build.screenshots`）と、リポジトリに置く撮れる画面の一覧
struct ScreenshotSettingsTests {
    private let validator = SchemaValidator(directory: Vectors.directory.deletingLastPathComponent().appendingPathComponent("schemas"))

    static let scenes = """
        {
          "v": 1,
          "scenes": [
            { "id": "inbox", "title": "あなたの番の一覧", "arguments": ["-demoScenario", "standard"] },
            { "id": "final-review", "title": "最終 PR の確認", "arguments": ["-demoOpen", "epic:tsundoku-search"] }
          ]
        }
        """

    @Test func readsScenes() throws {
        let file = try JSONDecoder().decode(ScreenshotScenesFile.self, from: Data(Self.scenes.utf8))
        #expect(file.problems.isEmpty)
        #expect(file.scene("final-review")?.arguments == ["-demoOpen", "epic:tsundoku-search"])
        #expect(file.scene("settings") == nil)
        let value = try JSONSerialization.jsonObject(with: Data(Self.scenes.utf8))
        #expect(try validator.errors(of: value, against: "screenshot-scenes.schema.json").isEmpty)
    }

    @Test func rejectsBrokenScenes() {
        let scene = ScreenshotScenesFile.Scene(id: "inbox", title: "一覧", arguments: [])
        #expect(ScreenshotScenesFile(scenes: []).problems == ["scenes は 1〜100 件"])
        #expect(!ScreenshotScenesFile(scenes: [scene, scene]).problems.isEmpty)
        // ファイル名に使うので、パスの区切りや大文字を受け付けない
        for id in ["../keys", "Inbox", "-inbox", "", String(repeating: "a", count: 41)] {
            #expect(!ScreenshotScenesFile(scenes: [.init(id: id, title: "一覧", arguments: [])]).problems.isEmpty, "\(id)")
        }
        #expect(!ScreenshotScenesFile(scenes: [.init(id: "inbox", title: "一覧", arguments: ["-a\n-b"])]).problems.isEmpty)
        #expect(!ScreenshotScenesFile(scenes: [.init(id: "inbox", title: "", arguments: [])]).problems.isEmpty)
        var future = ScreenshotScenesFile(scenes: [scene])
        future.version = 2
        #expect(!future.problems.isEmpty)
    }

    @Test func settingsNeedSimulatorAndJSONInsideRepository() {
        let phone = BuildDestination.simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro", osVersion: "27.0"))
        #expect(ScreenshotSettings(scenes: "AskHub/Demo/screenshot-scenes.json", destination: phone).problems.isEmpty)
        #expect(!ScreenshotSettings(scenes: "AskHub/Demo/screenshot-scenes.json", destination: .macOS).problems.isEmpty)
        #expect(!ScreenshotSettings(scenes: "../scenes.json", destination: phone).problems.isEmpty)
        #expect(!ScreenshotSettings(scenes: "scenes.yml", destination: phone).problems.isEmpty)
    }

    @Test func screenshotsAcceptOnlyGitHubAttachments() {
        let url = "https://github.com/user-attachments/assets/0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0"
        #expect(DecisionsFile.Screenshots.isAttachmentURL(url))
        #expect(!DecisionsFile.Screenshots.isAttachmentURL("https://example.com/user-attachments/assets/abc"))
        #expect(!DecisionsFile.Screenshots.isAttachmentURL(url + "?token=x"))
        #expect(!DecisionsFile.Screenshots.isAttachmentURL("https://github.com/user-attachments/assets/"))
        #expect(DecisionsFile.Screenshots(afterURL: url, note: "Before なし").problems.isEmpty)
        #expect(!DecisionsFile.Screenshots(note: "").problems.isEmpty)
    }
}
