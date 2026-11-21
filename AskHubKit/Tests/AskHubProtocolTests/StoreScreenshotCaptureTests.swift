import AskHubProtocol
import Foundation
import Testing

/// App Store のスクショの撮り方（`build.storeScreenshots` の `capture`）
struct StoreScreenshotCaptureTests {
    private static let actions = """
    {
      "capture": "actions",
      "workflow": "app-store-screenshots.yml",
      "artifacts": { "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE": "APP_IPHONE_67" },
      "languages": { "ja": { "language": "ja" }, "en-US": { "language": "en" } },
      "baseLocale": "ja"
    }
    """

    private static func decode(_ text: String) throws -> StoreScreenshotCapture {
        try JSONDecoder().decode(StoreScreenshotCapture.self, from: Data(text.utf8))
    }

    private static func encoded(_ capture: StoreScreenshotCapture) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(capture)) as? [String: Any])
    }

    @Test func readsTheOldShapeAsUITestAndWritesTheKind() throws {
        let old = """
        {
          "test": "OshiConUITests/AppStoreScreenshotTests",
          "languageVariable": "APP_STORE_LANGUAGE",
          "languages": { "ja": { "language": "ja", "region": "ja_JP" } },
          "baseLocale": "ja",
          "displayTypes": { "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE": ["iPhone 17 Pro Max"] }
        }
        """
        let capture = try Self.decode(old)
        guard case let .uiTest(settings) = capture else { Issue.record("uiTest として読めない"); return }
        #expect(settings.test == "OshiConUITests/AppStoreScreenshotTests" && capture.problems.isEmpty)
        // 書き出すときは capture をいつも書く（送った capture を、知らない欄として断らないように）
        let written = try Self.encoded(capture)
        #expect(written["capture"] as? String == "uiTest" && written["test"] as? String == "OshiConUITests/AppStoreScreenshotTests")
        #expect(try JSONDecoder().decode(StoreScreenshotCapture.self, from: try JSONEncoder().encode(capture)) == capture)
    }

    @Test func readsAndWritesTheWorkflowShape() throws {
        let capture = try Self.decode(Self.actions)
        guard case let .actions(workflow) = capture else { Issue.record("actions として読めない"); return }
        #expect(workflow.workflow == "app-store-screenshots.yml")
        #expect(workflow.artifacts["IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE"] == "APP_IPHONE_67")
        #expect(capture.kind == .actions && capture.baseLocale == "ja" && capture.problems.isEmpty)
        let written = try Self.encoded(capture)
        #expect(written["capture"] as? String == "actions")
        #expect((written["languages"] as? [String: [String: String]])?["en-US"] == ["language": "en"])
        #expect(written["test"] == nil)
    }

    @Test func findsProblemsOfTheWorkflowShape() {
        let workflow = StoreScreenshotWorkflow(
            workflow: "../upload.yml",
            artifacts: ["iphone": "APP IPHONE"],
            languages: ["ja": .init(language: "ja", region: "ja_JP")],
            baseLocale: "en-US"
        )
        let problems = StoreScreenshotCapture.actions(workflow).problems
        #expect(problems.contains { $0.contains("workflow") })
        #expect(problems.contains { $0.contains("artifacts は") })
        #expect(problems.contains { $0.contains("artifacts の値") })
        #expect(problems.contains { $0.contains("region は持たない") })
        #expect(problems.contains { $0.contains("baseLocale") })
    }

    @Test func refusesAnUnknownKind() {
        #expect(throws: DecodingError.self) {
            try Self.decode(#"{ "capture": "machine", "workflow": "a.yml" }"#)
        }
    }
}
