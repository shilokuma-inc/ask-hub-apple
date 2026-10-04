@testable import AskHubKit
import Testing

struct AskHubLabelTests {
    @Test func rawValuesMatchGitHubLabelNames() {
        #expect(AskHubLabel.needsAnswer.rawValue == "needs-answer")
        #expect(AskHubLabel.readyForLoop.rawValue == "ready-for-loop")
        #expect(AskHubLabel.decisionLog.rawValue == "decision-log")
        #expect(AskHubLabel.needsVerify.rawValue == "needs-verify")
        #expect(AskHubLabel.ideaRequest.rawValue == "idea-request")
        #expect(AskHubLabel.epicFinal.rawValue == "epic-final")
    }

    @Test func coversAllProtocolLabels() {
        #expect(AskHubLabel.allCases.count == 6)
    }
}
