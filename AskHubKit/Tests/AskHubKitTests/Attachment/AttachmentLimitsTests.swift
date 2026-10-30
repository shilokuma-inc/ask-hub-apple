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
        #expect(result.rejections == [.tooLarge(name: "big.pdf", limit: AttachmentLimits.maxFileSize)])
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

    @Test func zipHasItsOwnSizeLimit() {
        let zip = Data([0x50, 0x4B, 0x03, 0x04])
        let limit = AttachmentLimits.maxZipFileSize
        let exact = AttachmentFile(name: "ok.zip", type: "application/zip", data: zip + Data(count: limit - zip.count))
        let over = AttachmentFile(name: "big.zip", type: "application/zip", data: zip + Data(count: limit + 1 - zip.count))
        // zip 以外は 10 MB のまま（zip の上限は効かない）
        let image = file("big.png", size: AttachmentLimits.maxFileSize + 1)
        let result = AttachmentLimits.adding([exact, over, image], to: [])
        #expect(result.attachments.map(\.name) == ["ok.zip"])
        #expect(result.rejections == [
            .tooLarge(name: "big.zip", limit: AttachmentLimits.maxZipFileSize),
            .tooLarge(name: "big.png", limit: AttachmentLimits.maxFileSize)
        ])
        #expect(result.rejections.map(\.message) == [
            "big.zip は 50.0 MB を超えるため添付できません",
            "big.png は 10.0 MB を超えるため添付できません"
        ])
    }

    @Test func maxFileSizeDependsOnKind() {
        #expect(AttachmentLimits.maxZipFileSize == 52_428_800)
        #expect(AttachmentLimits.maxFileSize(for: .zip) == 52_428_800)
        #expect(AttachmentLimits.maxFileSize(for: .text) == 10_485_760)
        #expect(AttachmentLimits.maxFileSize(for: .image) == 10_485_760)
        #expect(AttachmentLimits.maxFileSize(for: .pdf) == 10_485_760)
    }

    @Test func rejectsSVGThatIsNotUTF8() {
        let svg = AttachmentFile(name: "icon.svg", type: "image/svg+xml", data: Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8))
        let broken = AttachmentFile(name: "broken.svg", type: "image/svg+xml", data: Data([0x3C, 0x73, 0xFF]))
        let result = AttachmentLimits.adding([svg, broken], to: [])
        #expect(result.attachments.map(\.name) == ["icon.svg"])
        #expect(result.rejections == [.notUTF8Text(name: "broken.svg")])
    }

    @Test func rejectsZipWhoseContentIsNotZip() {
        let local = AttachmentFile(name: "assets.zip", type: "application/zip", data: Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]))
        // 空の zip は、中央ディレクトリの終わり（`PK\u{05}\u{06}`）だけになる
        let endOfCentralDirectory = Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18))
        let empty = AttachmentFile(name: "empty.zip", type: "application/x-zip-compressed", data: endOfCentralDirectory)
        let text = AttachmentFile(name: "fake.zip", type: "application/zip", data: Data("not a zip".utf8))
        let short = AttachmentFile(name: "short.zip", type: "application/zip", data: Data([0x50, 0x4B]))
        let result = AttachmentLimits.adding([local, empty, text, short], to: [])
        #expect(result.attachments.map(\.name) == ["assets.zip", "empty.zip"])
        #expect(result.rejections == [.notZip(name: "fake.zip"), .notZip(name: "short.zip")])
        #expect(result.rejections.first?.message == "fake.zip は zip の形式として読めないため添付できません")
    }

    @Test func zipIsNotCheckedAsUTF8Text() {
        // zip の中身はバイナリ。UTF-8 の確かめはしない
        let zip = AttachmentFile(name: "a.zip", type: "application/zip", data: Data([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE]))
        #expect(AttachmentLimits.adding([zip], to: []).rejections.isEmpty)
    }
}
