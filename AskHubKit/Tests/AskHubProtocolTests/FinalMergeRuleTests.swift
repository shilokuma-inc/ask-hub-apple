import AskHubProtocol
import Foundation
import Testing

/// 最終 PR のマージの規則
struct FinalMergeRuleTests {
    static func item(_ id: String, visible: Bool?, answered: Bool = false) throws -> DecisionsFile.Item {
        let intent = IntentReference(
            keyId: try #require(KeyID(rawValue: "3GHenKEuXhau_ydZhSS8zpDFx5A1_I5K_ZMmfZsTw1Y")),
            nonce: try #require(ULID(rawValue: "01JCJ0C0000000000000000001"))
        )
        let answer = DecisionsFile.Answer(choice: .ok, intent: intent, at: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        return DecisionsFile.Item(id: id, task: "t1", visible: visible, what: "ボタンを右上に置く", why: "ゴールの t1", answer: answered ? answer : nil)
    }

    @Test func mergesAutomaticallyWithoutVisibleDecisionsOrRisks() throws {
        let internalOnly = DecisionsFile(items: [try Self.item("d1", visible: false)])
        #expect(FinalMergeRule.manualReasons(decisions: internalOnly, mergeRisks: []).isEmpty)
        #expect(FinalMergeRule.manualReasons(decisions: nil, mergeRisks: []).isEmpty)
    }

    @Test func visibleOrUnclassifiedDecisionsAndRisksNeedHuman() throws {
        let decisions = DecisionsFile(items: [
            try Self.item("d1", visible: true), try Self.item("d2", visible: nil), try Self.item("d3", visible: false)
        ])
        let risk = MergeRisk(kind: .sensitivePaths, reason: ".github/workflows/build.yml を変えた")
        #expect(FinalMergeRule.manualReasons(decisions: decisions, mergeRisks: [risk]) == [.visibleDecisions(count: 2), .risk(risk)])
    }

    @Test func approvalNeedsAnswersToEveryVisibleDecision() throws {
        #expect(FinalMergeRule.canApprove(decisions: nil))
        let answered = DecisionsFile(items: [try Self.item("d1", visible: true, answered: true), try Self.item("d2", visible: false)])
        #expect(FinalMergeRule.canApprove(decisions: answered))
        #expect(!FinalMergeRule.canApprove(decisions: DecisionsFile(items: [try Self.item("d1", visible: true)])))
        // 仕分ける前の仮決めは、見えるものとして答えを待つ
        #expect(!FinalMergeRule.canApprove(decisions: DecisionsFile(items: [try Self.item("d1", visible: nil)])))
    }
}
