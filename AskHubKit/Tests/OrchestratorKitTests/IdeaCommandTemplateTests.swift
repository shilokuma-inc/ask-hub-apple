@testable import OrchestratorKit
import Testing

struct IdeaCommandTemplateTests {
    private let repository = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/my apps/ask-hub-apple")

    @Test func defaultRunsClaudeHeadlessWithGhOnly() throws {
        #expect(try IdeaCommandTemplate() == IdeaCommandTemplate.standard)
        // プロンプトは標準入力で渡すので、引数には含めない
        #expect(IdeaCommandTemplate.standard.render(for: repository) == ["claude", "-p", "--allowedTools", "Bash(gh:*)"])
    }

    @Test func rendersRepositoryAndCheckoutPath() throws {
        let template = try IdeaCommandTemplate(arguments: ["/opt/bin/claude", "-p", "--add-dir", "{checkoutPath}", "--repo={repository}"])
        #expect(template.render(for: repository) == [
            "/opt/bin/claude", "-p", "--add-dir", "/src/my apps/ask-hub-apple", "--repo=shilokuma-inc/ask-hub-apple"
        ])
    }

    @Test func rejectsInvalidTemplates() {
        #expect(throws: OrchestratorConfigError.emptyIdeaCommand) {
            try IdeaCommandTemplate(arguments: [])
        }
        #expect(throws: OrchestratorConfigError.unknownIdeaPlaceholder("controlPath")) {
            try IdeaCommandTemplate(arguments: ["claude", "-p", "{controlPath}"])
        }
        #expect(throws: OrchestratorConfigError.unknownIdeaPlaceholder("prompt")) {
            try IdeaCommandTemplate(arguments: ["claude", "-p", "{prompt}"])
        }
    }
}
