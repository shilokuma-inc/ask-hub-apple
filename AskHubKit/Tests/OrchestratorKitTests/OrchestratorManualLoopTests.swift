import AskHubKit
import Foundation
@testable import OrchestratorKit
import Testing

// 手で回す Discussion（manual-loop）の扱い
extension OrchestratorTests {
    @Test func removesOnlyNeedsAnswerFromManualLoopDiscussion() async throws {
        let github = FakeGitHub([.success([])])
        let inbox = FakeInbox()
        func discussion(_ number: Int, author: String) -> InboxSubject {
            InboxSubject(
                kind: .discussion,
                nodeID: "D_\(number)",
                repository: "shilokuma-inc/ask-hub-apple",
                number: number,
                title: "依頼",
                url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/discussions/\(number)")!,
                author: author,
                labels: ["needs-answer", "manual-loop"]
            )
        }
        inbox.set(
            [discussion(273, author: "mrs1669"), discussion(274, author: "someone")],
            threads: [
                "D_273": [Self.ask("C_1", replies: ["mrs1669"])],
                "D_274": [Self.ask("C_2", replies: ["mrs1669"])]
            ]
        )
        try await makeOrchestrator(github: github, runtime: FakeRuntime(), inbox: inbox).pollOnce()

        // 手で回す Discussion には ready-for-loop を付けず、needs-answer だけを外す。
        // 信用外の author の Discussion に付いた manual-loop は無視する
        #expect(github.addedReady == ["D_274"])
        #expect(Set(github.removedNeedsAnswer) == ["D_273", "D_274"])
        #expect(logs.recorded.contains("shilokuma-inc/ask-hub-apple#273 は manual-loop（手で回す）なので、ready-for-loop は付けません"))
    }
}
