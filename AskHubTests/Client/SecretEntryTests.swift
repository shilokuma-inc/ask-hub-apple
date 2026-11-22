@testable import AskHub
import Testing

/// Secrets に入れる値の入力: 入れ始めたときのゴールの版を覚え、入れている間に版が変わったら消す
struct SecretEntryTests {
    @Test
    func remembersVersionWhenTypingStarts() {
        var entry = SecretEntry()
        entry.edit("a", goalVersion: 1)
        // 入れている途中で見えている版が進んでも、入れ始めたときの版のまま
        entry.edit("ab", goalVersion: 2)
        #expect(entry.value == "ab")
        #expect(entry.goalVersion == 1)
    }

    /// v1 で入れた値は、同じ作業が v2 に直されたら消す（Secrets の名前が変わったかもしれない）
    @Test
    func clearsValueWhenGoalIsRevised() {
        var entry = SecretEntry()
        entry.edit("old-token", goalVersion: 1)
        let sameVersion = entry.goalChanged(to: 1)
        #expect(!sameVersion)
        let revised = entry.goalChanged(to: 2)
        #expect(revised)
        #expect(entry.value.isEmpty)
        #expect(entry.goalVersion == nil)
        // 入れ直すと、新しい版を覚える
        entry.edit("new-token", goalVersion: 2)
        #expect(entry.goalVersion == 2)
        // 何も入れていなければ、版が変わっても消すものは無い
        var empty = SecretEntry()
        let cleared = empty.goalChanged(to: 3)
        #expect(!cleared)
    }
}
