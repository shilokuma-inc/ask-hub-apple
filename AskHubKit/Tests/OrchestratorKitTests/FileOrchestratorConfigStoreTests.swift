import Foundation
@testable import OrchestratorKit
import Testing

struct FileOrchestratorConfigStoreTests {
    private static let original = """
        {
          "trustedAuthors": ["mrs1669"],
          "repositories": [
            { "repository": "shilokuma-inc/ask-hub-apple", "path": "~/Desktop/ios/ask-hub-apple" },
            { "repository": "shilokuma-inc/notti-ios", "path": "~/Desktop/ios/notti-ios" }
          ],
          "pollIntervalSeconds": 60,
          "loopCommand": ["/Users/tester/.local/bin/askhub-start-loop", "{repository}"]
        }
        """

    /// 一時ディレクトリをホームディレクトリにして置いた設定ファイル
    private struct Fixture {
        let store: FileOrchestratorConfigStore
        let file: URL
        let home: String
    }

    private func makeStore() throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let file = home.appendingPathComponent("orchestrator.json")
        try Data(Self.original.utf8).write(to: file)
        let store = FileOrchestratorConfigStore(path: "~/orchestrator.json", loader: OrchestratorConfigLoader(homeDirectory: home.path))
        return Fixture(store: store, file: file, home: home.path)
    }

    @Test func addsRepositoryKeepingOtherKeysAndBacksUp() throws {
        let fixture = try makeStore()
        let (store, file, home) = (fixture.store, fixture.file, fixture.home)
        defer { try? FileManager.default.removeItem(atPath: home) }

        try store.addRepository("shilokuma-inc/my-quiz-ios", checkoutPath: home + "/Desktop/ios/my-quiz-ios")

        let config = try store.load()
        #expect(config.repositories.map(\.fullName) == [
            "shilokuma-inc/ask-hub-apple", "shilokuma-inc/notti-ios", "shilokuma-inc/my-quiz-ios"
        ])
        #expect(config.repositories.last?.checkoutPath == home + "/Desktop/ios/my-quiz-ios")
        #expect(config.pollInterval == .seconds(60))
        let text = try String(contentsOf: file, encoding: .utf8)
        // 手で書いた設定と同じく ~ で書く
        #expect(text.contains(#""path" : "~/Desktop/ios/my-quiz-ios""#))
        #expect(try String(contentsOf: file.appendingPathExtension("bak"), encoding: .utf8) == Self.original)

        // 既にあれば書かない
        try store.addRepository("Shilokuma-Inc/My-Quiz-iOS", checkoutPath: "/elsewhere")
        #expect(try store.load().repositories.count == 3)
    }

    @Test func removesRepositoryIgnoringCase() throws {
        let fixture = try makeStore()
        let (store, home) = (fixture.store, fixture.home)
        defer { try? FileManager.default.removeItem(atPath: home) }

        try store.removeRepository("Shilokuma-Inc/Notti-iOS")
        #expect(try store.load().repositories.map(\.fullName) == ["shilokuma-inc/ask-hub-apple"])
        // 無いものを外しても何もしない
        try store.removeRepository("shilokuma-inc/notti-ios")
        #expect(try store.load().repositories.count == 1)
    }

    @Test func refusesToWriteInvalidConfig() throws {
        let fixture = try makeStore()
        let (store, file, home) = (fixture.store, fixture.file, fixture.home)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try store.removeRepository("shilokuma-inc/notti-ios")
        let before = try Data(contentsOf: file)

        // 最後の担当リポジトリを外すと検証に通らないので、書かない
        #expect(throws: OrchestratorConfigError.noRepositories) {
            try store.removeRepository("shilokuma-inc/ask-hub-apple")
        }
        #expect(try Data(contentsOf: file) == before)
    }
}
