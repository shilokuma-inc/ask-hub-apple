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
        org: String = #""shilokuma-inc""#,
        repositories: String = #"[{ "repository": "shilokuma-inc/ask-hub-apple", "path": "~/src/ask-hub-apple" }]"#,
        pollIntervalSeconds: Int? = nil,
        loopCommand: String = #"["/usr/local/bin/start-loop", "{repository}"]"#
    ) -> String {
        var fields = [
            #""org": \#(org)"#,
            #""repositories": \#(repositories)"#,
            #""loopCommand": \#(loopCommand)"#
        ]
        if let trustedAuthors {
            fields.append(#""trustedAuthors": \#(trustedAuthors)"#)
        }
        if let pollIntervalSeconds {
            fields.append(#""pollIntervalSeconds": \#(pollIntervalSeconds)"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    @Test func decodesFullConfig() throws {
        let result = try decode(config(trustedAuthors: #"["mrs1669", "partner"]"#, pollIntervalSeconds: 90))

        #expect(result.trustedAuthorLogins == ["mrs1669", "partner"])
        #expect(result.trustedAuthors.contains("Partner"))
        #expect(result.org == "shilokuma-inc")
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
        let customField = #""ideaCommand": ["/opt/bin/claude", "-p", "--add-dir", "{checkoutPath}"], "org""#
        let custom = config().replacingOccurrences(of: #""org""#, with: customField)
        #expect(try decode(custom).ideaCommand.arguments == ["/opt/bin/claude", "-p", "--add-dir", "{checkoutPath}"])
        // プロンプトは標準入力で渡すので、{prompt} は使えない（古い書き方は設定エラーで気づける）
        let old = config().replacingOccurrences(of: #""org""#, with: #""ideaCommand": ["claude", "-p", "{prompt}"], "org""#)
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
        #expect(throws: OrchestratorConfigError.invalidJSON(reason: ".org がありません")) {
            try decode(#"{ "repositories": [], "loopCommand": ["x"] }"#)
        }
        #expect(throws: OrchestratorConfigError.invalidJSON(reason: ".repositories[0].path がありません")) {
            try decode(config(repositories: #"[{ "repository": "shilokuma-inc/a" }]"#))
        }
    }

    @Test func reportsTypeMismatchAndBrokenJSON() {
        #expect(throws: OrchestratorConfigError.invalidJSON(reason: ".pollIntervalSeconds の型が違います")) {
            try decode(config().replacingOccurrences(of: #""org""#, with: #""pollIntervalSeconds": "60", "org""#))
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
        #expect(throws: OrchestratorConfigError.emptyOrg) {
            try decode(config(org: #"" ""#))
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

    @Test func rejectsRepositoryOutsideOrg() {
        #expect(throws: OrchestratorConfigError.repositoryOutsideOrg(repository: "someone/app", org: "shilokuma-inc")) {
            try decode(config(repositories: #"[{ "repository": "someone/app", "path": "/src/app" }]"#))
        }
        // org の大文字・小文字は区別しない
        #expect(throws: Never.self) {
            try decode(config(repositories: #"[{ "repository": "Shilokuma-Inc/app", "path": "/src/app" }]"#))
        }
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
        #expect(result.org == "shilokuma-inc")
        #expect(result.repositories.first?.checkoutPath == directory.path + "/src/ask-hub-apple")
    }

    @Test func reportsMissingFile() {
        #expect(throws: OrchestratorConfigError.fileNotFound(path: "/Users/tester/.config/askhub/orchestrator.json")) {
            try loader.load(from: loader.defaultPath)
        }
    }
}
