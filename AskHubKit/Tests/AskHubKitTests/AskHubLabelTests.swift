@testable import AskHubKit
import Testing

struct AskHubLabelTests {
    @Test func rawValuesMatchGitHubLabelNames() {
        #expect(AskHubLabel.needsAnswer.rawValue == "needs-answer")
        #expect(AskHubLabel.readyForLoop.rawValue == "ready-for-loop")
        #expect(AskHubLabel.manualLoop.rawValue == "manual-loop")
        #expect(AskHubLabel.decisionLog.rawValue == "decision-log")
        #expect(AskHubLabel.needsVerify.rawValue == "needs-verify")
        #expect(AskHubLabel.ideaRequest.rawValue == "idea-request")
        #expect(AskHubLabel.epicFinal.rawValue == "epic-final")
        #expect(AskHubLabel.orchestratorHeartbeat.rawValue == "askhub-orchestrator")
        #expect(AskHubLabel.loopStatus.rawValue == "loop-status")
    }

    @Test func coversAllProtocolLabels() {
        #expect(AskHubLabel.allCases.count == 9)
    }
}
