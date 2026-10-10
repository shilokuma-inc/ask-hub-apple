@testable import AskHubKit
import Testing

struct DecisionLogItemTests {
    @Test func readsAllFieldsOfWellFormedLine() throws {
        let item = try #require(DecisionLogItem.parse(line: "- [ ] #319 表の区切り → 採用: カンマ区切り（別案: タブ区切り / 空白区切り）"))
        #expect(!item.isChecked)
        #expect(item.text == "#319 表の区切り → 採用: カンマ区切り（別案: タブ区切り / 空白区切り）")
        let decision = try #require(item.decision)
        #expect(decision.pullRequest == 319)
        #expect(decision.subject == "表の区切り")
        #expect(decision.adopted == "カンマ区切り")
        #expect(decision.alternatives == ["タブ区切り", "空白区切り"])
        #expect(decision.change == nil)
    }

    @Test func readsCheckedLines() {
        #expect(DecisionLogItem.parse(line: "- [x] #3 色 → 採用: 青")?.isChecked == true)
        #expect(DecisionLogItem.parse(line: "- [X] #3 色 → 採用: 青")?.isChecked == true)
        // 行頭の空白は無視する
        #expect(DecisionLogItem.parse(line: "  - [ ] #3 色 → 採用: 青")?.isChecked == false)
    }

    @Test func readsLineWithoutAlternatives() {
        let decision = DecisionLogItem.parse(line: "- [ ] #5 余白 → 採用: 16pt")?.decision
        #expect(decision?.adopted == "16pt")
        #expect(decision?.alternatives.isEmpty == true)
    }

    @Test func readsChangeAppendedByLoop() {
        let line = "- [x] #319 表の区切り → 採用: カンマ区切り（別案: タブ区切り / 空白区切り） → 変更: 別案 1（タブ区切り）"
        let decision = DecisionLogItem.parse(line: line)?.decision
        #expect(decision?.adopted == "カンマ区切り")
        #expect(decision?.alternatives == ["タブ区切り", "空白区切り"])
        #expect(decision?.change == "別案 1（タブ区切り）")
    }

    @Test func splitsChangeAtLastSeparator() {
        // 採用の値に区切りと同じ文字列があっても、ループが末尾に追記した変更と取り違えない
        let decision = DecisionLogItem.parse(line: "- [x] #6 区切り → 採用: 「 → 変更: 」 → 変更: 短縮")?.decision
        #expect(decision?.adopted == "「 → 変更: 」")
        #expect(decision?.change == "短縮")
    }

    @Test func keepsParenthesesInsideValues() {
        // 採用・別案の中の括弧は、末尾の（別案: …）と取り違えない
        let line = "- [ ] #4 文言 → 採用: 「保存」（短い）（別案: 「完了」（丁寧） / 「済」）"
        let decision = DecisionLogItem.parse(line: line)?.decision
        #expect(decision?.subject == "文言")
        #expect(decision?.adopted == "「保存」（短い）")
        #expect(decision?.alternatives == ["「完了」（丁寧）", "「済」"])
    }

    @Test func subjectEndsAtFirstAdoptedSeparator() {
        let decision = DecisionLogItem.parse(line: "- [ ] #7 矢印 → の向き → 採用: 右 → 採用: 左")?.decision
        #expect(decision?.subject == "矢印 → の向き")
        #expect(decision?.adopted == "右 → 採用: 左")
    }

    @Test func keepsMalformedCheckboxLinesAsText() throws {
        let lines = [
            "- [ ] 番号の無い判断 → 採用: 青",
            "- [ ] #12 採用の無い判断",
            "- [ ] #abc 色 → 採用: 青",
            "- [ ] #8  → 採用: 青",
            "- [ ] #9 色 → 採用: （別案: 赤）",
            "- [ ] #10 色 → 採用: 青（別案: 赤 / ）",
            "- [ ] #11 色 → 採用: 青（別案: ）"
        ]
        for line in lines {
            let item = try #require(DecisionLogItem.parse(line: line))
            #expect(item.decision == nil)
            #expect(item.text == line.dropFirst("- [ ] ".count).trimmingCharacters(in: .whitespaces))
        }
    }

    @Test func listsOnlyCheckboxLinesInOrder() {
        let body = """
            チェックを付けたものは承認。変更したいものはコメントで `#<PR番号> は別案 1 で` のように指示。

            - [x] #3 色 → 採用: 青
            - [ ] #4 文言 → 採用: 「保存」（別案: 「完了」）
            * 箇条書きだがチェックではない
            - [ ] 形式に合わない行\r
            """
        let items = DecisionLogItem.items(in: body)
        #expect(items.map(\.text) == ["#3 色 → 採用: 青", "#4 文言 → 採用: 「保存」（別案: 「完了」）", "形式に合わない行"])
        #expect(items.map(\.isChecked) == [true, false, false])
        #expect(items.map { $0.decision?.pullRequest } == [3, 4, nil])
    }

    @Test func ignoresNonCheckboxLines() {
        #expect(DecisionLogItem.parse(line: "#3 色 → 採用: 青") == nil)
        #expect(DecisionLogItem.parse(line: "- #3 色 → 採用: 青") == nil)
        #expect(DecisionLogItem.items(in: "").isEmpty)
    }
}
