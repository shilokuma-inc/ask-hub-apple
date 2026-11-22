@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// クリエイティブアセットの Claude の案: 撮影の設定の読み方と、案の確かめ
struct CreativeDraftTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!

    func repository(languages: String?, screenshots: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-creative-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("AppStore"), withIntermediateDirectories: true)
        if let languages { try Data(languages.utf8).write(to: directory.appendingPathComponent("AppStore/languages.json")) }
        if let screenshots { try Data(screenshots.utf8).write(to: directory.appendingPathComponent("AppStore/screenshots.json")) }
        return directory
    }

    static let languages = #"""
        {"languages": [
          {"language": "ja", "appleLanguage": "ja", "appleLocale": "ja_JP", "storeLocale": "ja"},
          {"language": "en", "appleLanguage": "en", "appleLocale": "en_US", "storeLocale": "en-US"},
          {"language": "../x", "appleLanguage": "x", "appleLocale": "x", "storeLocale": "fr-FR"}
        ]}
        """#
    static let screenshots = #"{"scenes": [{"file": "01_home", "scene": "home"}, {"file": "02_quiz", "scene": "quiz"}]}"#

    @Test func readsTheScreenshotSettings() throws {
        let directory = try repository(languages: Self.languages, screenshots: Self.screenshots)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = try CreativeRepositoryConfig.read(in: directory)
        // 形の違う言語のフォルダは使わない
        #expect(config.folders == ["ja": "ja", "en-US": "en"])
        #expect(config.screens == ["01_home", "02_quiz"])
    }

    @Test func refusesRepositoriesWithoutTheSettings() throws {
        let directory = try repository(languages: nil, screenshots: Self.screenshots)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: ReleaseNotesFailure.self) { try CreativeRepositoryConfig.read(in: directory) }
        do {
            _ = try CreativeRepositoryConfig.read(in: directory)
        } catch {
            #expect(!error.retryable && error.message.contains("AppStore/languages.json が無い"))
        }
    }

    @Test func fillsNamesAndFoldersAndChecksTheOutput() throws {
        let config = CreativeRepositoryConfig(folders: ["ja": "ja", "en-US": "en"], screens: ["01_home", "02_quiz"])
        let request = CreativeDraftRequest(
            repo: Self.repo,
            appName: "素数ピック",
            commit: String(repeating: "a", count: 40),
            locales: [
                .init(locale: "en-US", appName: "Prime Pick", listing: ListingText(locale: "en-US")),
                .init(locale: "ja", appName: "素数ピック", listing: ListingText(locale: "ja"))
            ]
        )
        let output = ClaudeCreativeDrafter.Output(
            reason: "素数を見抜く速さを見出しにしました",
            colors: .init(background: "#101820", accent: "#4FC3F7", text: "#FFFFFF"),
            screens: .init(header: ["01_home", "02_quiz"], search: ["02_quiz"]),
            locales: [
                .init(locale: "ja", header: .init(title: "素数を*一瞬*で"), search: .init(title: "数の勘を鍛える")),
                .init(locale: "en-US", header: .init(title: "Spot primes *fast*"), search: .init(title: "Train number sense"))
            ]
        )
        let spec = output.spec(request, config: config)
        // 言語は材料の順、アプリ名と撮影のフォルダは材料から埋める
        #expect(spec.locales.map(\.locale) == ["en-US", "ja"])
        #expect(spec.locales.map(\.appName) == ["Prime Pick", "素数ピック"] && spec.locales.map(\.screenshots) == ["en", "ja"])
        #expect(ClaudeCreativeDrafter.problems(output, request: request, config: config).isEmpty)

        var missing = output
        missing.locales.removeLast()
        missing.screens.search = ["09_none"]
        missing.locales[0].search.title = "無料で使える"
        let problems = ClaudeCreativeDrafter.problems(missing, request: request, config: config)
        #expect(problems.contains("locales に en-US が無い（すべての言語を書く）"))
        #expect(problems.contains("screens に撮らない画面（09_none）がある"))
        #expect(problems.contains { $0.contains("価格") })
    }

    @Test func promptsWithTheMaterials() {
        let config = CreativeRepositoryConfig(folders: ["ja": "ja"], screens: ["01_home"])
        let request = CreativeDraftRequest(
            repo: Self.repo,
            appName: "素数ピック",
            commit: String(repeating: "a", count: 40),
            locales: [.init(locale: "ja", appName: "素数ピック", listing: ListingText(locale: "ja", description: "素数を当てるゲーム"))],
            previous: CreativeProtocolFixtures.spec,
            comment: "見出しを短く"
        )
        let prompt = ClaudeCreativeDrafter.prompt(request, config: config)
        #expect(prompt.contains("使える画面（撮影の画面の名前。撮る順）: 01_home"))
        #expect(prompt.contains("素数を当てるゲーム") && prompt.contains("人が直してほしいこと: 見出しを短く"))
        guard case let .object(schema) = ClaudeCreativeDrafter.schema(locales: ["ja"], screens: ["01_home"]),
              case let .object(properties)? = schema["properties"] else {
            Issue.record("schema の形が違う")
            return
        }
        #expect(Set(properties.keys) == ["reason", "colors", "screens", "locales"])
    }
}
