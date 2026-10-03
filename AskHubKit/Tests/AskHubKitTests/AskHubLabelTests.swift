@testable import AskHubKit
import Testing

struct AskHubLabelTests {
    @Test func rawValuesMatchGitHubLabelNames() {
        #expect(AskHubLabel.needsAnswer.rawValue == "needs-answer")
        #expect(AskHubLabel.readyForLoop.rawValue == "ready-for-loop")
    }
}
