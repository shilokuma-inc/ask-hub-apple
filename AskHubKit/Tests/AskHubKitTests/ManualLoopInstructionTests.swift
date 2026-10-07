@testable import AskHubKit
import Testing

struct ManualLoopInstructionTests {
    @Test func followsRequestFormatOfClaudeMarkdown() {
        let instruction = ManualLoopInstruction.make(repository: "shilokuma-inc/notti-ios", discussionNumber: 12)

        #expect(instruction.hasPrefix("shilokuma-inc/notti-ios で epic/<機能名> のループを回したい。ゴールは Discussion #12。手動で回して"))
    }
}
