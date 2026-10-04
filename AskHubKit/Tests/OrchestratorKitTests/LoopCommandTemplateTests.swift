@testable import OrchestratorKit
import Testing

struct LoopCommandTemplateTests {
    private let repository = RepositoryConfig(
        owner: "shilokuma-inc",
        name: "ask-hub-apple",
        checkoutPath: "/src/my apps/ask-hub-apple"
    )

    @Test func rendersPlaceholdersInEachArgument() throws {
        let template = try LoopCommandTemplate(arguments: [
            "/usr/local/bin/start-loop",
            "--repo={repository}",
            "{checkoutPath}",
            "{controlPath}"
        ])

        #expect(template.render(for: repository) == [
            "/usr/local/bin/start-loop",
            "--repo=shilokuma-inc/ask-hub-apple",
            // 空白を含んでも 1 つの引数のまま
            "/src/my apps/ask-hub-apple",
            "/src/my apps/ask-hub-apple-ralph-ctl"
        ])
    }

    @Test func doesNotReplaceTwice() throws {
        let tricky = RepositoryConfig(owner: "shilokuma-inc", name: "app", checkoutPath: "/src/{repository}")
        let template = try LoopCommandTemplate(arguments: ["{checkoutPath}"])
        #expect(template.render(for: tricky) == ["/src/{repository}"])
    }

    @Test func ignoresBracesThatAreNotPlaceholders() throws {
        let template = try LoopCommandTemplate(arguments: ["--json", #"{"a": 1}"#, "{}", "{repo_name}"])
        #expect(template.render(for: repository) == ["--json", #"{"a": 1}"#, "{}", "{repo_name}"])
    }

    @Test func rejectsEmptyCommand() {
        #expect(throws: OrchestratorConfigError.emptyLoopCommand) {
            try LoopCommandTemplate(arguments: [])
        }
        #expect(throws: OrchestratorConfigError.emptyLoopCommand) {
            try LoopCommandTemplate(arguments: ["", "{repository}"])
        }
    }

    @Test func rejectsUnknownPlaceholder() {
        #expect(throws: OrchestratorConfigError.unknownPlaceholder("ctl")) {
            try LoopCommandTemplate(arguments: ["start", "{repository}", "--dir={ctl}"])
        }
    }
}
