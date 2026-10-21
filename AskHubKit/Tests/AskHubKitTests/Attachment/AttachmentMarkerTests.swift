@testable import AskHubKit
import Foundation
import Testing

struct AttachmentMarkerTests {
    private static let sha = String(repeating: "a", count: 40)
    private static let commit = String(repeating: "0123456789", count: 4)
    private static let id = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    private func marker(
        path: String = "files/\(Self.id)/design.png",
        sha: String = Self.sha,
        commit: String = Self.commit,
        name: String = "design.png",
        size: Int = 120_000,
        type: String = "image/png"
    ) -> AttachmentMarker {
        AttachmentMarker(path: path, sha: sha, commit: commit, name: name, size: size, type: type)
    }

    @Test func roundTrips() {
        let original = marker()
        #expect(AttachmentMarker.parseAll(original.marker) == [original])
    }

    @Test func markerIsSingleHTMLComment() {
        let text = marker().marker
        #expect(text.hasPrefix("<!-- ask-hub:attachment {"))
        #expect(text.hasSuffix("} -->"))
        #expect(!text.contains("\n"))
        #expect(text.contains(#""path":"files/\#(Self.id)/design.png""#))
    }

    @Test func escapesGreaterThanInName() {
        let original = marker(name: "a-->b>c.png")
        let text = original.marker
        // 目印の終わりは最後の `-->` だけ
        #expect(text.components(separatedBy: "-->").count == 2)
        #expect(text.contains(#"\u003e"#))
        #expect(AttachmentMarker.parseAll(text) == [original])
    }

    @Test func parsesAllMarkersAnywhereInBody() {
        let first = marker()
        let second = marker(path: "files/\(UUID().uuidString.lowercased())/memo.md", name: "memo.md", size: 10, type: "text/markdown")
        let body = """
        回答: 案1
        補足です。

        ### 添付ファイル
        - [design.png](https://example.com)（画像・117 KB）
        \(first.marker)
        - [memo.md](https://example.com)（テキスト・10 B）
        \(second.marker)
        """
        #expect(AttachmentMarker.parseAll(body) == [first, second])
    }

    @Test func ignoresDuplicatedPath() {
        let original = marker()
        let duplicated = marker(name: "other.png")
        #expect(AttachmentMarker.parseAll(original.marker + "\n" + duplicated.marker) == [original])
    }

    @Test func ignoresOtherMarkers() {
        let body = """
        <!-- ask-hub:verify-problem -->
        <!-- ask-hub:attachments-cleaned {"count":1} -->
        <!-- ask-hub:attachment -->
        <!-- ask-hub:attachment {not json} -->
        """
        #expect(AttachmentMarker.parseAll(body).isEmpty)
    }

    @Test func ignoresUnclosedComment() {
        let text = marker().marker
        #expect(AttachmentMarker.parseAll(String(text.dropLast(3))).isEmpty)
    }

    @Test(arguments: [
        "design.png",
        "files/design.png",
        "files/\(id)/../design.png",
        "files/\(id)/..",
        "files/\(id)/",
        "files/\(id.uppercased())/design.png",
        "files/not-a-uuid/design.png",
        "other/\(id)/design.png",
        "/files/\(id)/design.png",
        "files/\(id)/.hidden",
        "files/\(id)/a\\b.png"
    ])
    func ignoresMalformedPath(path: String) {
        #expect(AttachmentMarker.parseAll(marker(path: path).marker).isEmpty)
    }

    @Test(arguments: [
        String(repeating: "a", count: 39),
        String(repeating: "a", count: 41),
        String(repeating: "A", count: 40),
        String(repeating: "g", count: 40),
        String(repeating: "１", count: 40),
        ""
    ])
    func ignoresMalformedObjectID(value: String) {
        #expect(AttachmentMarker.parseAll(marker(sha: value).marker).isEmpty)
        #expect(AttachmentMarker.parseAll(marker(commit: value).marker).isEmpty)
    }

    @Test func ignoresNegativeSizeAndEmptyFields() {
        #expect(AttachmentMarker.parseAll(marker(size: -1).marker).isEmpty)
        #expect(AttachmentMarker.parseAll(marker(name: "").marker).isEmpty)
        #expect(AttachmentMarker.parseAll(marker(type: "").marker).isEmpty)
    }

    @Test func ignoresUnknownKeysAndAcceptsAnyKeyOrder() {
        let body = """
        <!-- ask-hub:attachment {"type":"application/pdf","size":3,"name":"a.pdf","future":true,\
        "commit":"\(Self.commit)","sha":"\(Self.sha)","path":"files/\(Self.id)/a.pdf"} -->
        """
        #expect(AttachmentMarker.parseAll(body) == [
            marker(path: "files/\(Self.id)/a.pdf", name: "a.pdf", size: 3, type: "application/pdf")
        ])
    }

    @Test func buildsPathWithLowercasedUUIDAndSanitizedName() throws {
        let id = try #require(UUID(uuidString: Self.id.uppercased()))
        #expect(AttachmentMarker.path(id: id, fileName: "../デザイン/案.png") == "files/\(Self.id)/デザイン案.png")
        #expect(marker(path: AttachmentMarker.path(id: id, fileName: "...")).isWellFormed)
    }

    @Test func kindFollowsMIMEType() {
        #expect(marker(type: "image/png").kind == .image)
        #expect(marker(type: "IMAGE/WEBP").kind == .image)
        #expect(marker(type: "application/pdf").kind == .pdf)
        #expect(marker(type: "text/markdown").kind == .text)
        #expect(marker(type: "application/json").kind == .text)
    }
}
