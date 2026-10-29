@testable import AskHubKit
import Foundation
import Testing

struct AttachmentSectionTests {
    private static let commit = String(repeating: "c", count: 40)
    private static let id = "3f2504e0-4f89-11d3-9a0c-0305e82c3301"

    private func marker(name: String = "design.png", size: Int = 120_000, type: String = "image/png") -> AttachmentMarker {
        AttachmentMarker(
            path: "files/\(Self.id)/\(AttachmentFileName.sanitized(name))",
            sha: String(repeating: "b", count: 40),
            commit: Self.commit,
            name: name,
            size: size,
            type: type
        )
    }

    @Test func returnsBodyUnchangedWithoutAttachments() {
        let body = "依頼文です。\n\n"
        #expect(AttachmentSection.appending([], to: body, repository: "o/r") == body)
    }

    @Test func appendsSectionAtEnd() {
        let attachment = marker()
        let result = AttachmentSection.appending([attachment], to: "依頼文です。\n", repository: "shilokuma-inc/ask-hub-apple")
        #expect(result == """
        依頼文です。

        ### 添付ファイル
        - [design.png](https://github.com/shilokuma-inc/ask-hub-apple/blob/\(Self.commit)/files/\(Self.id)/design.png)（画像・117 KB）
          \(attachment.marker)
        """)
    }

    @Test func sectionOnlyWhenBodyIsEmpty() {
        let result = AttachmentSection.appending([marker()], to: "  \n", repository: "o/r")
        #expect(result.hasPrefix(AttachmentSection.heading))
    }

    @Test func keepsLeadingMarkersAndAnswerLine() {
        let attachments = [marker(), marker(name: "memo.md", size: 10, type: "text/markdown")]
        let answer = AttachmentSection.appending(attachments, to: "回答: 案1\n補足です。", repository: "o/r")
        #expect(answer.hasPrefix("回答: 案1\n補足です。\n\n### 添付ファイル\n"))
        #expect(AttachmentMarker.parseAll(answer) == attachments)

        let problem = AttachmentSection.appending(attachments, to: "<!-- ask-hub:verify-problem -->\n落ちます", repository: "o/r")
        #expect(problem.hasPrefix("<!-- ask-hub:verify-problem -->\n落ちます\n\n"))
        #expect(AttachmentMarker.parseAll(problem) == attachments)

        let verify = VerifyMarker(pullRequest: 12, epic: "epic/x")
        let issue = AttachmentSection.appending(attachments, to: verify.marker + "\n本文", repository: "o/r")
        #expect(VerifyMarker.parse(issue) == verify)
    }

    @Test func linkUsesPercentEncodedCommitPermalink() throws {
        let attachment = marker(name: "デザイン 案.png")
        let url = try #require(AttachmentSection.url(for: attachment, repository: "o/r"))
        #expect(url.absoluteString == "https://github.com/o/r/blob/\(Self.commit)/files/\(Self.id)/"
            + "%E3%83%87%E3%82%B6%E3%82%A4%E3%83%B3%20%E6%A1%88.png")
    }

    @Test func linkKeepsFileNameStartingWithCombiningCharacter() throws {
        let name = "\u{0301}x.png"
        let attachment = AttachmentMarker(
            path: "files/\(Self.id)/\(name)",
            sha: String(repeating: "b", count: 40),
            commit: Self.commit,
            name: name,
            size: 1,
            type: "image/png"
        )
        let url = try #require(AttachmentSection.url(for: attachment, repository: "o/r"))
        #expect(url.absoluteString == "https://github.com/o/r/blob/\(Self.commit)/files/\(Self.id)/%CC%81x.png")
    }

    @Test func escapesMarkdownInLinkText() {
        let result = AttachmentSection.appending([marker(name: "[a](b)*_.png")], to: "", repository: "o/r")
        #expect(result.contains(#"- [\[a\]\(b\)\*\_.png](https://"#))
    }

    @Test func replacesNewlinesInDisplayName() {
        let result = AttachmentSection.appending([marker(name: "a\nb.txt", size: 1, type: "text/plain")], to: "", repository: "o/r")
        #expect(result.contains("- [a b.txt]("))
    }

    @Test func renderedBodyShowsOnlyLinks() {
        let attachments = [marker(), marker(name: "spec.pdf", size: 3 * 1_024 * 1_024, type: "application/pdf")]
        let body = AttachmentSection.appending(attachments, to: "依頼文です。", repository: "o/r")
        let plain = RenderedBody(body: body).plainText
        #expect(!plain.contains("ask-hub:attachment"))
        #expect(plain.contains("design.png（画像・117 KB）"))
        #expect(plain.contains("spec.pdf（PDF・3.0 MB）"))
    }

    @Test func showsZipAndSVGKinds() {
        let attachments = [
            marker(name: "assets.zip", size: 3 * 1_024 * 1_024, type: "application/zip"),
            marker(name: "icon.svg", size: 2_048, type: "image/svg+xml")
        ]
        let plain = RenderedBody(body: AttachmentSection.appending(attachments, to: "依頼文です。", repository: "o/r")).plainText
        #expect(plain.contains("assets.zip（zip・3.0 MB）"))
        #expect(plain.contains("icon.svg（画像・2 KB）"))
    }
}

struct AttachmentFileNameTests {
    @Test(arguments: [
        ("design.png", "design.png"),
        ("a/b\\c.png", "abc.png"),
        ("..hidden.txt", "hidden.txt"),
        (".\u{0301}hidden", "\u{0301}hidden"),
        ("tab\tand\nnewline.txt", "tabandnewline.txt"),
        ("  spaced.md  ", "spaced.md"),
        ("", "attachment"),
        ("...", "attachment"),
        ("/\\", "attachment")
    ])
    func sanitizes(input: String, expected: String) {
        #expect(AttachmentFileName.sanitized(input) == expected)
    }

    @Test func shortensKeepingExtension() {
        let result = AttachmentFileName.sanitized(String(repeating: "あ", count: 150) + ".png")
        #expect(result.count == AttachmentFileName.maxLength)
        #expect(result.hasSuffix("あ.png"))
    }

    @Test(arguments: [
        ". x.png",
        "..  x.png",
        " . .x.png",
        String(repeating: "a", count: 99) + " b",
        String(repeating: "a", count: 98) + " .png" + String(repeating: "b", count: 10),
        "\u{3000}全角の空白.png\u{3000}"
    ])
    func sanitizingTwiceKeepsResult(input: String) {
        let once = AttachmentFileName.sanitized(input)
        #expect(AttachmentFileName.sanitized(once) == once)
        #expect(once.first?.isWhitespace != true && once.last?.isWhitespace != true)
        #expect(!once.hasPrefix("."))
    }

    @Test func shortensWithoutExtension() {
        let result = AttachmentFileName.sanitized(String(repeating: "a", count: 150))
        #expect(result == String(repeating: "a", count: AttachmentFileName.maxLength))
    }
}

struct AttachmentSizeTests {
    @Test(arguments: [
        (0, "0 B"),
        (1_023, "1023 B"),
        (1_024, "1 KB"),
        (1_048_063, "1023 KB"),
        (1_048_575, "1.0 MB"),
        (120_000, "117 KB"),
        (1_048_576, "1.0 MB"),
        (10 * 1_048_576, "10.0 MB")
    ])
    func displayText(bytes: Int, expected: String) {
        #expect(AttachmentSize.displayText(bytes: bytes) == expected)
    }
}
