@testable import OrchestratorKit
import Testing

struct IdeaCommandTemplateTests {
    private let repository = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/my apps/ask-hub-apple")

    @Test func defaultRunsClaudeHeadlessWithGhAndAttachmentsReadOnly() throws {
        #expect(try IdeaCommandTemplate() == IdeaCommandTemplate.standard)
        #expect(IdeaCommandTemplate.standard.usesAttachmentsPath)
        // プロンプトは標準入力で渡すので、引数には含めない。`Read` の絶対パスは `//` で始める
        let path = "/Users/me/Library/Caches/askhub/attachments/o/r/issue-7"
        #expect(IdeaCommandTemplate.standard.render(for: repository, attachmentsPath: path) == [
            "claude", "-p",
            "--allowedTools", "Bash(gh:*)", "Read(//Users/me/Library/Caches/askhub/attachments/o/r/issue-7/**)",
            "--add-dir", "/Users/me/Library/Caches/askhub/attachments/o/r/issue-7"
        ])
    }

    @Test func customCommandWithoutAttachmentsPath() throws {
        let template = try IdeaCommandTemplate(arguments: ["claude", "-p", "--allowedTools", "Bash(gh:*)"])
        #expect(!template.usesAttachmentsPath)
        #expect(template.render(for: repository, attachmentsPath: "/tmp/x") == ["claude", "-p", "--allowedTools", "Bash(gh:*)"])
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
