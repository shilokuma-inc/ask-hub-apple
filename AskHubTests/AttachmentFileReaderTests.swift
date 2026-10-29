@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// 添付欄で選んだファイルの読み取り（Discussion #669）
@MainActor
struct AttachmentFileReaderTests {
    private static func temporaryFile(_ name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "askhub-reader-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test(arguments: [
        ("a.png", "image/png"),
        ("a.jpg", "image/jpeg"),
        ("a.pdf", "application/pdf"),
        ("a.json", "application/json"),
        ("a.txt", "text/plain"),
        ("a.csv", "text/csv"),
        ("a.zip", "application/zip"),
        ("a.svg", "image/svg+xml")
    ])
    func mimeTypeFromExtension(name: String, expected: String) {
        #expect(AttachmentFileReader.mimeType(for: URL(filePath: "/tmp/\(name)")) == expected)
    }

    @Test func textTypesAreReadAsText() {
        // YAML・Markdown は「テキスト」として扱う（UTF-8 の確認を受ける）
        for name in ["a.yaml", "a.md"] {
            let type = AttachmentFileReader.mimeType(for: URL(filePath: "/tmp/\(name)"))
            #expect(AttachmentKind(mimeType: type) == .text, "\(name) → \(type)")
        }
        #expect(AttachmentFileReader.mimeType(for: URL(filePath: "/tmp/noextension")) == "application/octet-stream")
    }

    @Test func readsNameTypeAndContent() throws {
        let url = try Self.temporaryFile("memo.md", data: Data("# メモ".utf8))
        let file = try AttachmentFileReader.read(url).get()
        #expect(file.name == "memo.md")
        #expect(file.data == Data("# メモ".utf8))
        #expect(AttachmentKind(mimeType: file.type) == .text)
    }

    @Test func rejectsTooLargeFileBeforeReading() throws {
        let url = try Self.temporaryFile("big.pdf", data: Data(count: AttachmentLimits.maxFileSize + 1))
        #expect(throws: AttachmentFileReader.Failure.self) {
            try AttachmentFileReader.read(url).get()
        }
        if case let .failure(failure) = AttachmentFileReader.read(url) {
            #expect(failure.message == "big.pdf は 10.0 MB を超えるため添付できません")
        }
    }

    @Test func reportsUnreadableFile() {
        let url = URL(filePath: "/tmp/askhub-missing-\(UUID().uuidString).png")
        if case let .failure(failure) = AttachmentFileReader.read(url) {
            #expect(failure.message == "\(url.lastPathComponent) を読み込めませんでした")
        } else {
            Issue.record("読めないはず")
        }
    }

    @Test func allowedTypesMatchSpecification() {
        #expect(AttachmentPickerSection.allowedContentTypes.count == 12)
        #expect(AttachmentPickerSection.allowedContentTypes.contains(.zip))
        #expect(AttachmentPickerSection.allowedContentTypes.contains(.svg))
        #expect(!AttachmentPickerSection.allowedContentTypes.contains(.heic))
    }

    /// 中身を書かずに大きさだけを持つファイルを作る（大きなファイルの上限の確かめで、ディスクとメモリを使わない）
    private static func sparseFile(_ name: String, size: Int) throws -> URL {
        let url = try temporaryFile(name, data: Data([0x50, 0x4B, 0x03, 0x04]))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        return url
    }

    @Test func readsZipOverTenMegabytes() throws {
        let url = try Self.sparseFile("assets.zip", size: AttachmentLimits.maxFileSize + 1)
        let file = try AttachmentFileReader.read(url).get()
        #expect(file.type == "application/zip")
        #expect(file.data.count == AttachmentLimits.maxFileSize + 1)
    }

    @Test func rejectsZipOverFiftyMegabytesBeforeReading() throws {
        let url = try Self.sparseFile("big.zip", size: AttachmentLimits.maxZipFileSize + 1)
        if case let .failure(failure) = AttachmentFileReader.read(url) {
            #expect(failure.message == "big.zip は 50.0 MB を超えるため添付できません")
        } else {
            Issue.record("50 MB を超える zip は断るはず")
        }
    }
}
