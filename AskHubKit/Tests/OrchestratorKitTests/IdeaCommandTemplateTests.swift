@testable import OrchestratorKit
import Testing

struct IdeaCommandTemplateTests {
    private let repository = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/my apps/ask-hub-apple")

    @Test func defaultRunsClaudeHeadlessWithGhOnly() throws {
        #expect(try IdeaCommandTemplate() == IdeaCommandTemplate.standard)
        let rendered = IdeaCommandTemplate.standard.render(prompt: "考察して {repository} は置き換えない", for: repository)
        // プロンプトは 1 つの引数のまま渡し、中の `{...}` は置き換えない
        #expect(rendered == ["claude", "-p", "考察して {repository} は置き換えない", "--allowedTools", "Bash(gh:*)"])
    }

    @Test func rendersRepositoryAndCheckoutPath() throws {
        let template = try IdeaCommandTemplate(arguments: [
            "/opt/bin/claude", "-p", "{prompt}", "--add-dir", "{checkoutPath}", "--repo={repository}"
        ])
        #expect(template.render(prompt: "P", for: repository) == [
            "/opt/bin/claude", "-p", "P", "--add-dir", "/src/my apps/ask-hub-apple", "--repo=shilokuma-inc/ask-hub-apple"
        ])
    }

    @Test func rejectsInvalidTemplates() {
        #expect(throws: OrchestratorConfigError.emptyIdeaCommand) {
            try IdeaCommandTemplate(arguments: [])
        }
        #expect(throws: OrchestratorConfigError.unknownIdeaPlaceholder("controlPath")) {
            try IdeaCommandTemplate(arguments: ["claude", "-p", "{prompt}", "{controlPath}"])
        }
        #expect(throws: OrchestratorConfigError.ideaCommandWithoutPrompt) {
            try IdeaCommandTemplate(arguments: ["claude", "-p"])
        }
    }
}
