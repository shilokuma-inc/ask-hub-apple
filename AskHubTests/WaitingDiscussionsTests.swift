@testable import AskHub
import AskHubKit
import Foundation
import Testing

@MainActor
struct WaitingDiscussionsTests {
    @Test func loadsWaitingDiscussionsWithInbox() async {
        let model = InboxModel(tokenStore: InMemoryTokenStore(token: "sample"), makeSource: { _ in SampleInboxSource() })
        await model.refresh()

        #expect(model.waiting.map(\.subject.shortReference) == ["ask-hub-apple#15", "beat-tap-ios#3"])
        // 印の新しいリポジトリは担当 PC あり、印の無いリポジトリは担当 PC なし
        #expect(model.waiting.map { $0.isAssigned(now: Date()) } == [true, false])
    }

    @Test func clearsWaitingDiscussionsWithoutToken() async {
        let model = InboxModel(tokenStore: InMemoryTokenStore(), makeSource: { _ in SampleInboxSource() })
        await model.refresh()
        #expect(model.waiting.isEmpty)
    }
}
