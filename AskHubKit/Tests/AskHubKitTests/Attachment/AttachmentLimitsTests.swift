@testable import AskHubKit
import Foundation
import Testing

struct AttachmentLimitsTests {
    private func file(_ name: String, size: Int = 3, type: String = "image/png") -> AttachmentFile {
        AttachmentFile(name: name, type: type, data: Data(repeating: 0x41, count: size))
    }

    @Test func addsInSelectedOrder() {
        let result = AttachmentLimits.adding([file("b.png"), file("c.png")], to: [file("a.png")])
        #expect(result.attachments.map(\.name) == ["a.png", "b.png", "c.png"])
        #expect(result.rejections.isEmpty)
    }

    @Test func rejectsFileOverSizeLimitButKeepsExactLimit() {
        let result = AttachmentLimits.adding(
            [file("big.pdf", size: AttachmentLimits.maxFileSize + 1), file("ok.pdf", size: AttachmentLimits.maxFileSize)],
            to: []
        )
        #expect(result.attachments.map(\.name) == ["ok.pdf"])
        #expect(result.rejections == [.tooLarge(name: "big.pdf")])
        #expect(result.rejections.first?.message == "big.pdf は 10.0 MB を超えるため添付できません")
    }

    @Test func rejectsBeyondMaxCount() {
        let current = (1...9).map { file("\($0).png") }
        let result = AttachmentLimits.adding([file("10.png"), file("11.png"), file("12.png")], to: current)
        #expect(result.attachments.count == AttachmentLimits.maxCount)
        #expect(result.attachments.last?.name == "10.png")
        #expect(result.rejections == [.tooMany(name: "11.png"), .tooMany(name: "12.png")])
        #expect(result.rejections.first?.message == "添付は 10 ファイルまでです（11.png は足していません）")
    }

    @Test func rejectsTextThatIsNotUTF8AndEmptyFile() {
        let notUTF8 = AttachmentFile(name: "sjis.txt", type: "text/plain", data: Data([0x82, 0xA0, 0xFF]))
        let utf8 = AttachmentFile(name: "memo.md", type: "text/markdown", data: Data("# メモ".utf8))
        let binaryImage = AttachmentFile(name: "a.png", type: "image/png", data: Data([0x89, 0xFF]))
        let result = AttachmentLimits.adding([notUTF8, utf8, binaryImage, file("empty.png", size: 0)], to: [])
        #expect(result.attachments.map(\.name) == ["memo.md", "a.png"])
        #expect(result.rejections == [.notUTF8Text(name: "sjis.txt"), .empty(name: "empty.png")])
    }
}
