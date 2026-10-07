import Foundation
@testable import OrchestratorKit
import Testing

struct OrchestratorConfigLoaderTests {
    private let loader = OrchestratorConfigLoader(homeDirectory: "/Users/tester")

    private func decode(_ json: String) throws(OrchestratorConfigError) -> OrchestratorConfig {
        try loader.decode(Data(json.utf8))
    }

    private func config(
        trustedAuthors: String? = nil,
        repositories: String = #"[{ "repository": "shilokuma-inc/ask-hub-apple", "path": "~/src/ask-hub-apple" }]"#,
        pollIntervalSeconds: Int? = nil,
        iterationTimeoutMinutes: Int? = nil,
        loopCommand: String = #"["/usr/local/bin/start-loop", "{repository}"]"#
    ) -> String {
        var fields = [
            #""repositories": \#(repositories)"#,
            #""loopCommand": \#(loopCommand)"#
        ]
        if let trustedAuthors {
            fields.append(#""trustedAuthors": \#(trustedAuthors)"#)
        }
        if let pollIntervalSeconds {
            fields.append(#""pollIntervalSeconds": \#(pollIntervalSeconds)"#)
        }
        if let iterationTimeoutMinutes {
            fields.append(#""iterationTimeoutMinutes": \#(iterationTimeoutMinutes)"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test func decodesFullConfig() throws {
        let result = try decode(config(trustedAuthors: #"["mrs1669", "partner"]"#, pollIntervalSeconds: 90))

        #expect(result.trustedAuthorLogins == ["mrs1669", "partner"])
        #expect(result.trustedAuthors.contains("Partner"))
        #expect(result.orgs == ["shilokuma-inc"])
        #expect(result.repositories == [
            RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/Users/tester/src/ask-hub-apple")
        ])
        #expect(result.pollInterval == .seconds(90))
        #expect(result.loopCommand.arguments == ["/usr/local/bin/start-loop", "{repository}"])
    }

    @Test func trimsTrustedAuthors() throws {
        let result = try decode(config(trustedAuthors: #"[" mrs1669 ", " "]"#))

        #expect(result.trustedAuthorLogins == ["mrs1669"])
    }

    @Test func readsIdeaCommandOrUsesDefault() throws {
        #expect(try decode(config()).ideaCommand == IdeaCommandTemplate.standard)
        let customField = #""ideaCommand": ["/opt/bin/claude", "-p", "--add-dir", "{checkoutPath}"], "repositories""#
        let custom = config().replacingOccurrences(of: #""repositories""#, with: customField)
        #expect(try decode(custom).ideaCommand.arguments == ["/opt/bin/claude", "-p", "--add-dir", "{checkoutPath}"])
        // プロンプトは標準入力で渡すので、{prompt} は使えない（古い書き方は設定エラーで気づける）
        let oldField = #""ideaCommand": ["claude", "-p", "{prompt}"], "repositories""#
        let old = config().replacingOccurrences(of: #""repositories""#, with: oldField)
        #expect(throws: OrchestratorConfigError.unknownIdeaPlaceholder("prompt")) {
            try decode(old)
        }
    }

    @Test func appliesDefaults() throws {
        let result = try decode(config())

        #expect(result.trustedAuthorLogins == ["mrs1669"])
        #expect(result.pollInterval == OrchestratorConfig.defaultPollInterval)
    }

    @Test func reportsMissingKey() {
        #expect(throws: OrchestratorConfigError.invalidJSON(reason: ".repositories がありません")) {
            try decode(#"{ "loopCommand": ["x"] }"#)
        }
        #expect(throws: OrchestratorConfigError.invalidJSON(reason: ".repositories[0].path がありません")) {
            try decode(config(repositories: #"[{ "repository": "shilokuma-inc/a" }]"#))
        }
    }

    @Test func reportsTypeMismatchAndBrokenJSON() {
        #expect(throws: OrchestratorConfigError.invalidJSON(reason: ".pollIntervalSeconds の型が違います")) {
            try decode(config().replacingOccurrences(of: #""repositories""#, with: #""pollIntervalSeconds": "60", "repositories""#))
        }
        #expect(throws: OrchestratorConfigError.invalidJSON(reason: "JSON として読めません")) {
            try decode("{")
        }
    }

    @Test func rejectsEmptyValues() {
        #expect(throws: OrchestratorConfigError.emptyTrustedAuthors) {
            try decode(config(trustedAuthors: #"[""]"#))
        }
        #expect(throws: OrchestratorConfigError.emptyTrustedAuthors) {
            try decode(config(trustedAuthors: #"[" ", "\n"]"#))
        }
        #expect(throws: OrchestratorConfigError.noRepositories) {
            try decode(config(repositories: "[]"))
        }
        #expect(throws: OrchestratorConfigError.emptyLoopCommand) {
            try decode(config(loopCommand: "[]"))
        }
    }

    @Test(arguments: [
        "ask-hub-apple", "shilokuma-inc/", "/ask-hub-apple", "shilokuma-inc/a/b", "shilokuma-inc/a b",
        "shilokuma-inc/foo\nbar", "shilokuma-inc/foo\tbar", "shilokuma-inc/foo\u{7F}"
    ])
    func rejectsInvalidRepositoryName(_ name: String) throws {
        // 改行などを含む値も JSON として正しく埋め込むため、文字列をエンコードしてから渡す
        let encodedName = try #require(String(data: JSONEncoder().encode(name), encoding: .utf8))
        #expect(throws: OrchestratorConfigError.invalidRepositoryName(name)) {
            try decode(config(repositories: #"[{ "repository": \#(encodedName), "path": "/src" }]"#))
        }
    }

    @Test func searchesOwnersOfRepositories() throws {
        let repositories = #"""
            [{ "repository": "shilokuma-inc/a", "path": "/src/a" },
             { "repository": "BeaconFun4/b", "path": "/src/b" },
             { "repository": "Shilokuma-Inc/c", "path": "/src/c" }]
            """#
        // owner は大文字・小文字を区別せずに重ねない
        #expect(try decode(config(repositories: repositories)).orgs == ["shilokuma-inc", "BeaconFun4"])
        // 以前の設定の org は無視する（担当リポジトリが別の organization にあっても読める）
        let legacy = config().replacingOccurrences(of: #""repositories""#, with: #""org": "someone", "repositories""#)
        #expect(try decode(legacy).orgs == ["shilokuma-inc"])
    }

    @Test func rejectsDuplicateRepositoryIgnoringCase() {
        let repositories = #"""
            [{ "repository": "shilokuma-inc/app", "path": "/src/a" },
             { "repository": "shilokuma-inc/App", "path": "/src/b" }]
            """#
        #expect(throws: OrchestratorConfigError.duplicateRepository("shilokuma-inc/App")) {
            try decode(config(repositories: repositories))
        }
    }

    @Test func rejectsRelativeCheckoutPath() {
        #expect(throws: OrchestratorConfigError.relativeCheckoutPath(repository: "shilokuma-inc/app", path: "src/app")) {
            try decode(config(repositories: #"[{ "repository": "shilokuma-inc/app", "path": "src/app" }]"#))
        }
    }

    @Test func normalizesCheckoutPath() throws {
        let result = try decode(config(repositories: #"[{ "repository": "shilokuma-inc/app", "path": "/src/x/../app/" }]"#))
        #expect(result.repositories.first?.checkoutPath == "/src/app")
    }

    @Test func rejectsTooShortPollInterval() throws {
        #expect(throws: OrchestratorConfigError.pollIntervalTooShort(seconds: 29, minimum: 30)) {
            try decode(config(pollIntervalSeconds: 29))
        }
        #expect(try decode(config(pollIntervalSeconds: 30)).pollInterval == .seconds(30))
    }

    @Test func readsIterationTimeoutWithDefaultAndMinimum() throws {
        #expect(try decode(config()).iterationTimeout == .seconds(90 * 60))
        #expect(try decode(config(iterationTimeoutMinutes: 120)).iterationTimeout == .seconds(120 * 60))
        #expect(throws: OrchestratorConfigError.iterationTimeoutOutOfRange(minutes: 9, minimum: 10, maximum: 1440)) {
            try decode(config(iterationTimeoutMinutes: 9))
        }
        // 秒に変換するとあふれる値も、落ちずに設定エラーにする
        #expect(throws: OrchestratorConfigError.iterationTimeoutOutOfRange(minutes: Int.max, minimum: 10, maximum: 1440)) {
            try decode(config(iterationTimeoutMinutes: Int.max))
        }
    }

    @Test func rejectsUnknownPlaceholder() {
        #expect(throws: OrchestratorConfigError.unknownPlaceholder("repo")) {
            try decode(config(loopCommand: #"["start", "{repo}"]"#))
        }
    }

    @Test func loadsFileAndExpandsTildeInPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(config().utf8).write(to: directory.appendingPathComponent("orchestrator.json"))

        let homeLoader = OrchestratorConfigLoader(homeDirectory: directory.path)
        let result = try homeLoader.load(from: "~/orchestrator.json")
        #expect(result.orgs == ["shilokuma-inc"])
        #expect(result.repositories.first?.checkoutPath == directory.path + "/src/ask-hub-apple")
    }

    @Test func reportsMissingFile() {
        #expect(throws: OrchestratorConfigError.fileNotFound(path: "/Users/tester/.config/askhub/orchestrator.json")) {
            try loader.load(from: loader.defaultPath)
        }
    }
    @Test func readsRepositoryCommandsOrUsesDefaults() throws {
        let standard = try decode(config()).repositoryCommands
        #expect(standard == RepositoryCommands(
            create: ["/Users/tester/.local/bin/askhub-create-repo"],
            remove: ["/Users/tester/.local/bin/askhub-remove-repo"],
            // 最初の担当リポジトリと同じ場所に clone する
            newCheckoutDirectory: "/Users/tester/src"
        ))
        #expect(standard.checkoutPath(for: "my-quiz-ios") == "/Users/tester/src/my-quiz-ios")

        let fields = #""createRepositoryCommand": ["~/bin/create", "-v"], "removeRepositoryCommand": ["/opt/remove"], "#
            + #""newRepositoryDirectory": "~/Desktop/ios/", "repositories""#
        let custom = try decode(config().replacingOccurrences(of: #""repositories""#, with: fields)).repositoryCommands
        #expect(custom == RepositoryCommands(
            create: ["/Users/tester/bin/create", "-v"],
            remove: ["/opt/remove"],
            newCheckoutDirectory: "/Users/tester/Desktop/ios"
        ))
    }

    @Test func rejectsEmptyRepositoryCommandOrRelativeDirectory() {
        #expect(throws: OrchestratorConfigError.emptyRepositoryCommand(key: "createRepositoryCommand")) {
            try decode(config().replacingOccurrences(of: #""repositories""#, with: #""createRepositoryCommand": [], "repositories""#))
        }
        #expect(throws: OrchestratorConfigError.relativeNewRepositoryDirectory("src")) {
            try decode(config().replacingOccurrences(of: #""repositories""#, with: #""newRepositoryDirectory": "src", "repositories""#))
        }
    }
}
