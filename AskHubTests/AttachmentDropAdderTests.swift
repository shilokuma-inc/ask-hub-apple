@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// ドロップされた項目を添付にする処理（Discussion #784 のタスク 2）
@MainActor
struct AttachmentDropAdderTests {
    /// テストごとに一時ディレクトリを作り、終わったら消す
    private final class Directory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "askhub-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        @discardableResult
        func file(_ path: String, data: Data = Data("内容".utf8)) throws -> URL {
            let file = url.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            return file
        }

        @discardableResult
        func folder(_ path: String) throws -> URL {
            let folder = url.appending(path: path, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        /// 受け付ける種類のファイルを `count` 個置いたフォルダ
        func folder(_ path: String, textFiles count: Int) throws -> URL {
            let folder = try folder(path)
            for index in 0 ..< count {
                try file("\(path)/\(String(format: "%02d", index)).txt")
            }
            return folder
        }
    }

    private static func existing(_ count: Int) -> [AttachmentFile] {
        (0 ..< count).map { AttachmentFile(name: "既存\($0).txt", type: "text/plain", data: Data("x".utf8)) }
    }

    // MARK: - ファイル

    @Test func addsDroppedFilesInOrder() throws {
        let directory = try Directory()
        let memo = try directory.file("memo.md")
        let png = try directory.file("design.png", data: Data([0x89, 0x50, 0x4E, 0x47]))

        let outcome = AttachmentDropAdder.add([.fileURL(memo), .fileURL(png)], to: Self.existing(1))

        #expect(outcome.attachments.map(\.name) == ["既存0.txt", "memo.md", "design.png"])
        #expect(outcome.notices.isEmpty)
    }

    @Test(arguments: ["photo.heic", "spec.docx", "app.exe", "noextension"])
    func rejectsTypesThatCannotBePicked(name: String) throws {
        let directory = try Directory()
        let file = try directory.file(name)

        let outcome = AttachmentDropAdder.add([.fileURL(file)], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == [AttachmentDropAdder.unsupportedTypeNotice(name: name)])
    }

    @Test(arguments: [
        "a.txt", "a.md", "a.json", "a.csv", "a.yaml", "a.yml",
        "a.png", "a.jpg", "a.gif", "a.webp", "a.svg", "a.pdf", "a.zip"
    ])
    func acceptsTypesThatCanBePicked(name: String) {
        #expect(AttachmentDropAdder.isAllowedType(URL(filePath: "/tmp/\(name)")))
    }

    @Test func addsUpToLimitAndRejectsTheRestOneByOne() throws {
        let directory = try Directory()
        let first = try directory.file("a.txt")
        let second = try directory.file("b.txt")

        let outcome = AttachmentDropAdder.add([.fileURL(first), .fileURL(second)], to: Self.existing(AttachmentLimits.maxCount - 1))

        #expect(outcome.attachments.count == AttachmentLimits.maxCount)
        #expect(outcome.attachments.last?.name == "a.txt")
        #expect(outcome.notices == ["添付は 10 ファイルまでです（b.txt は足していません）"])
    }

    @Test func reportsUnreadableFileAndAddsTheRest() throws {
        let directory = try Directory()
        let missing = directory.url.appending(path: "missing.png")
        let fine = try directory.file("fine.txt")

        let outcome = AttachmentDropAdder.add([.fileURL(missing), .fileURL(fine)], to: [])

        #expect(outcome.attachments.map(\.name) == ["fine.txt"])
        #expect(outcome.notices == ["missing.png を読み込めませんでした"])
    }

    @Test func doesNotFollowDroppedSymbolicLink() throws {
        let directory = try Directory()
        let target = try directory.file("secret.txt")
        let link = directory.url.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let outcome = AttachmentDropAdder.add([.fileURL(link)], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == ["link.txt はシンボリックリンクのため添付できません（元のファイルを落としてください）"])
    }

    @Test func rejectsDroppedPackage() throws {
        let directory = try Directory()
        try directory.file("Tool.app/Contents/readme.txt")

        let outcome = AttachmentDropAdder.add([.fileURL(directory.url.appending(path: "Tool.app"))], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == [AttachmentDropAdder.unsupportedTypeNotice(name: "Tool.app")])
    }

    @Test func rejectsFileThatIsNotRegular() throws {
        let directory = try Directory()
        // 読み込みが終わらない FIFO（拡張子は受け付ける種類）
        let fifo = directory.url.appending(path: "pipe.txt")
        #expect(mkfifo(fifo.path, 0o600) == 0)

        let outcome = AttachmentDropAdder.add([.fileURL(fifo)], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == [AttachmentDropAdder.unsupportedTypeNotice(name: "pipe.txt")])
    }

    // MARK: - ファイル以外・空

    @Test func rejectsNonFileItemsWithOneNotice() throws {
        let directory = try Directory()
        let file = try directory.file("a.txt")
        let web = try #require(URL(string: "https://example.com/image.png"))

        let outcome = AttachmentDropAdder.add([.other, .fileURL(web), .fileURL(file), .other], to: [])

        #expect(outcome.attachments.map(\.name) == ["a.txt"])
        #expect(outcome.notices == [AttachmentDropAdder.otherItemsNotice])
    }

    @Test func emptyDropChangesNothing() {
        let current = Self.existing(2)
        let outcome = AttachmentDropAdder.add([], to: current)
        #expect(outcome.attachments == current)
        #expect(outcome.notices.isEmpty)
    }

    // MARK: - フォルダ

    @Test func expandsFolderIncludingSubfoldersWithoutStructure() throws {
        let directory = try Directory()
        let folder = try directory.folder("資料")
        try directory.file("資料/b.md")
        try directory.file("資料/sub/a.txt")
        try directory.file("資料/sub/deeper/c.json", data: Data("{}".utf8))

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        // 構造は残さず名前だけ。パスの名前の順に並ぶ
        #expect(outcome.attachments.map(\.name) == ["b.md", "a.txt", "c.json"])
        #expect(outcome.notices.isEmpty)
    }

    @Test func skipsHiddenFilesSilentlyAndExplainsExcludedTypes() throws {
        let directory = try Directory()
        let folder = try directory.folder("資料")
        try directory.file("資料/.DS_Store")
        try directory.file("資料/.hidden/inside.txt")
        try directory.file("資料/memo.txt")
        try directory.file("資料/photo.heic")
        try directory.file("資料/spec.docx")
        try directory.file("資料/table.xlsx")
        try directory.file("資料/video.mov")

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        #expect(outcome.attachments.map(\.name) == ["memo.txt"])
        #expect(outcome.notices == ["フォルダ 資料 の中の 4 項目は、添付できない種類・シンボリックリンク・パッケージのため除きました（photo.heic・spec.docx・table.xlsx など）"])
    }

    @Test func excludesSymbolicLinksAndPackagesInFolder() throws {
        let directory = try Directory()
        let outside = try directory.file("outside/secret.txt")
        let outsideFolder = outside.deletingLastPathComponent()
        let folder = try directory.folder("資料")
        try directory.file("資料/memo.txt")
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "link.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "linked-folder"), withDestinationURL: outsideFolder)
        try directory.file("資料/Tool.app/Contents/readme.txt")

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        #expect(outcome.attachments.map(\.name) == ["memo.txt"])
        #expect(outcome.notices == ["フォルダ 資料 の中の 3 項目は、添付できない種類・シンボリックリンク・パッケージのため除きました（link.txt・linked-folder・Tool.app）"])
    }

    @Test func addsFolderUpToExactLimit() throws {
        let directory = try Directory()
        let folder = try directory.folder("資料", textFiles: AttachmentLimits.maxCount - 2)

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: Self.existing(2))

        #expect(outcome.attachments.count == AttachmentLimits.maxCount)
        #expect(outcome.notices.isEmpty)
    }

    @Test func rejectsWholeFolderOverLimit() throws {
        let directory = try Directory()
        let folder = try directory.folder("資料", textFiles: AttachmentLimits.maxCount + 1)

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == ["フォルダ 資料 の 11 ファイルを足すと 10 ファイルを超えるため、1 つも足していません（今の添付は 0 ファイル）"])
    }

    @Test func rejectsWholeFolderWhenOverLimitWithExisting() throws {
        let directory = try Directory()
        // 例: 3 つ添付済みで、受け付ける種類のファイルが 8 つのフォルダ（ゴールの注意点）
        let folder = try directory.folder("資料", textFiles: 8)
        try directory.file("資料/photo.heic")
        let current = Self.existing(3)

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: current)

        #expect(outcome.attachments == current)
        #expect(outcome.notices == [
            "フォルダ 資料 の中の 1 項目は、添付できない種類・シンボリックリンク・パッケージのため除きました（photo.heic）",
            "フォルダ 資料 の 8 ファイルを足すと 10 ファイルを超えるため、1 つも足していません（今の添付は 3 ファイル）"
        ])
    }

    @Test func explainsFolderWithoutAcceptedFiles() throws {
        let directory = try Directory()
        let folder = try directory.folder("写真")
        try directory.file("写真/a.heic")

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == [
            "フォルダ 写真 の中の 1 項目は、添付できない種類・シンボリックリンク・パッケージのため除きました（a.heic）",
            "フォルダ 写真 の中に、添付できる種類のファイルがありません"
        ])
    }

    @Test func folderFilesThatCannotBeReadAreExplainedOneByOne() throws {
        let directory = try Directory()
        let folder = try directory.folder("資料")
        try directory.file("資料/a.txt")
        try directory.file("資料/empty.txt", data: Data())

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        #expect(outcome.attachments.map(\.name) == ["a.txt"])
        #expect(outcome.notices == ["empty.txt は中身が空のため添付できません"])
    }

    @Test func stopsWalkingHugeFolder() throws {
        let directory = try Directory()
        let folder = try directory.folder("大きい", textFiles: 5)

        #expect(AttachmentDropAdder.contents(of: folder, maxEntries: 4).isTooLarge)
        // ちょうど上限の数なら、たどりきる
        #expect(!AttachmentDropAdder.contents(of: folder, maxEntries: 5).isTooLarge)
        #expect(AttachmentDropAdder.contents(of: folder, maxEntries: 5).files.count == 5)
    }

    @Test func rejectsWholeHugeFolderWithNotice() throws {
        let directory = try Directory()
        let folder = try directory.folder("大きい")
        // 受け付けない種類で数だけを増やす（1 つも足さないことを、数の上限ではなく項目の多さで確かめる）
        for index in 0 ... AttachmentDropAdder.maxFolderEntries {
            try directory.file("大きい/\(index).dat", data: Data())
        }

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == ["フォルダ 大きい は中の項目が多すぎるため、1 つも足していません（1000 項目まで）"])
    }

    @Test func explainsEmptyFolder() throws {
        let directory = try Directory()
        let folder = try directory.folder("空")

        let outcome = AttachmentDropAdder.add([.fileURL(folder)], to: [])

        #expect(outcome.attachments.isEmpty)
        #expect(outcome.notices == ["フォルダ 空 の中に、添付できる種類のファイルがありません"])
    }

    @Test func filesAndFoldersAreJudgedInDroppedOrder() throws {
        let directory = try Directory()
        let file = try directory.file("single.txt")
        let folder = try directory.folder("資料", textFiles: AttachmentLimits.maxCount)

        // 先にファイルを足すと、フォルダは合わせて上限を超えるので 1 つも足さない
        let fileFirst = AttachmentDropAdder.add([.fileURL(file), .fileURL(folder)], to: [])
        #expect(fileFirst.attachments.map(\.name) == ["single.txt"])
        #expect(fileFirst.notices.count == 1)

        // 先にフォルダを足すと、続くファイルは数の上限で断る
        let folderFirst = AttachmentDropAdder.add([.fileURL(folder), .fileURL(file)], to: [])
        #expect(folderFirst.attachments.count == AttachmentLimits.maxCount)
        #expect(folderFirst.notices == ["添付は 10 ファイルまでです（single.txt は足していません）"])
    }
}
