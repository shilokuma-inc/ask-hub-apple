@testable import AskHubKit
import Testing

struct AttachmentKindTests {
    @Test func followsMIMEType() {
        #expect(AttachmentKind(mimeType: "image/png") == .image)
        #expect(AttachmentKind(mimeType: "IMAGE/WEBP") == .image)
        #expect(AttachmentKind(mimeType: "application/pdf") == .pdf)
        #expect(AttachmentKind(mimeType: "application/pdf; name=a.pdf") == .pdf)
        #expect(AttachmentKind(mimeType: "image/png ; charset=binary") == .image)
        #expect(AttachmentKind(mimeType: "text/markdown") == .text)
        #expect(AttachmentKind(mimeType: "application/json") == .text)
        #expect(AttachmentKind(mimeType: "application/zip") == .zip)
        #expect(AttachmentKind(mimeType: "Application/X-Zip-Compressed") == .zip)
        // SVG は画像として表示する
        #expect(AttachmentKind(mimeType: "image/svg+xml") == .image)
        // 知らないバイナリはテキスト扱いのまま（UTF-8 の確かめで断る）
        #expect(AttachmentKind(mimeType: "application/octet-stream") == .text)
    }

    @Test func displayNames() {
        #expect([AttachmentKind.text, .image, .pdf, .zip].map(\.displayName) == ["テキスト", "画像", "PDF", "zip"])
    }

    @Test func detectsSVG() {
        #expect(AttachmentKind.isSVG(mimeType: "image/svg+xml"))
        #expect(AttachmentKind.isSVG(mimeType: "IMAGE/SVG+XML; charset=utf-8"))
        #expect(!AttachmentKind.isSVG(mimeType: "image/png"))
        #expect(!AttachmentKind.isSVG(mimeType: "text/xml"))
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
