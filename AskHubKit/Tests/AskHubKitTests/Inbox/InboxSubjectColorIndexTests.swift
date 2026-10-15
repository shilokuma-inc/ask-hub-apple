@testable import AskHubKit
import Foundation
import Testing

struct InboxSubjectColorIndexTests {
    @Test func fnv1aMatchesKnownValues() {
        // FNV-1a（64 ビット）の公開されているテスト値。プロセスや OS によらず同じ値になる
        #expect(InboxSubject.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(InboxSubject.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
    }

    @Test func colorIndexComesFromNodeIDOnly() {
        #expect(InboxSubject.fixture(nodeID: "D_kwDOU6o4_M4AhV9r").colorIndex(paletteCount: 8) == 1)
        // 1 文字違いの node id でも別の色になりうる
        #expect(InboxSubject.fixture(nodeID: "D_kwDOU6o4_M4AhV9s").colorIndex(paletteCount: 8) == 6)
        // タイトルや番号が変わっても、node id が同じなら同じ色
        var renamed = InboxSubject.fixture(nodeID: "D_kwDOU6o4_M4AhV9r")
        renamed.title = "別のタイトル"
        renamed.number = 99
        #expect(renamed.colorIndex(paletteCount: 8) == 1)
    }

    @Test func colorIndexStaysInPalette() {
        let indices = (0..<50).compactMap { InboxSubject.fixture(nodeID: "D_\($0)").colorIndex(paletteCount: 6) }
        #expect(indices.count == 50)
        #expect(indices.allSatisfy { (0..<6).contains($0) })
        // 偏って 1 色に寄らない
        #expect(Set(indices).count == 6)
        #expect(InboxSubject.fixture().colorIndex(paletteCount: 0) == nil)
    }

    @Test func pullRequestHasNoColor() {
        #expect(InboxSubject.fixture(kind: .pullRequest, nodeID: "PR_kwDOU6o4_M6Abcde").colorIndex(paletteCount: 6) == nil)
    }
}
