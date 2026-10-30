import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - zip の展開（Discussion #761 の Q2。docs/protocol.md の「zip の展開」）

struct AttachmentZipExtractorTests {
    /// テストの一時ディレクトリ。zip はこの直下に置き、`out` に展開する
    private let directory: URL
    private let archive: URL
    private let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "askhub-zip-\(UUID().uuidString)", directoryHint: .isDirectory)
        archive = directory.appending(path: "in.zip", directoryHint: .notDirectory)
        destination = directory.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var root: String {
        String(destination.path(percentEncoded: false).dropLast())
    }

    private func extract(
        _ entries: [TestZipEntry],
        limits: AttachmentZipExtractor.Limits = .default
    ) throws -> AttachmentZipContents {
        try TestZip.build(entries).write(to: archive)
        return try AttachmentZipExtractor(limits: limits).extract(zipAt: archive, to: destination)
    }

    private func expectError(
        _ expected: AttachmentZipError,
        _ entries: [TestZipEntry],
        limits: AttachmentZipExtractor.Limits = .default
    ) throws {
        #expect(throws: expected) {
            try extract(entries, limits: limits)
        }
        // zip 全体を展開できなければ、展開先は残さない
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    /// テストの一時ディレクトリの中で、zip と展開先の外にあるもの（あってはいけない）
    private func filesOutsideDestination() -> [String] {
        let base = directory.path(percentEncoded: false)
        let paths = FileManager.default.subpaths(atPath: base) ?? []
        return paths.filter { $0 != "in.zip" && $0 != "out" && !$0.hasPrefix("out/") }
    }

    /// コマンドを起動して終了を待ち、終了コードを返す（出力は捨てるのでパイプは詰まらない。時間には頼らない）
    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func contents(of path: String) -> String? {
        FileManager.default.contents(atPath: path).flatMap { String(bytes: $0, encoding: .utf8) }
    }

    // MARK: - 読めるファイルと素材

    @Test func classifiesReadableFilesAndMaterialsByExtension() throws {
        let readme = String(repeating: "# 画面の素材\n", count: 50)
        let result = try extract([
            .directory("docs/"),
            TestZipEntry("docs/readme.md", readme, method: 8),
            TestZipEntry(bytes: Array("images/logo.png".utf8), Data([0x89, 0x50, 0x4E, 0x47, 0xFF])),
            TestZipEntry("icon.SVG", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"),
            TestZipEntry("spec.pdf", "%PDF-1.7"),
            TestZipEntry("fonts/dummy.ttf", "not a font"),
            TestZipEntry("nested.zip", "PK"),
            // バイナリの plist はテキストとして読めないので素材にする
            TestZipEntry(bytes: Array("data.plist".utf8), Data([0x62, 0x70, 0x6C, 0x69, 0xFF, 0xFE])),
            TestZipEntry("LICENSE", "no extension")
        ])

        #expect(result.directory == root)
        #expect(result.readableFiles.map(\.entryPath) == ["docs/readme.md", "images/logo.png", "icon.SVG", "spec.pdf"])
        #expect(result.readableFiles.map(\.type) == ["text/markdown", "image/png", "image/svg+xml", "application/pdf"])
        #expect(result.readableFiles.map(\.kind) == [.text, .image, .image, .pdf])
        #expect(result.readableFiles.map(\.path) == result.readableFiles.map { "\(root)/\($0.entryPath)" })
        #expect(result.readableFiles.first?.size == readme.utf8.count)
        #expect(result.materials.map(\.entryPath) == ["fonts/dummy.ttf", "nested.zip", "data.plist", "LICENSE"])
        #expect(result.materials.map(\.size) == [10, 2, 6, 12])
        #expect(result.skippedEntries.isEmpty)
        // Deflate の項目も中身どおりに展開する
        #expect(contents(of: "\(root)/docs/readme.md") == readme)
        // zip の中の zip は展開しない
        #expect(contents(of: "\(root)/nested.zip") == "PK")
        #expect(filesOutsideDestination().isEmpty)
    }

    @Test func extractsZip64SizesAndNormalizesDotComponents() throws {
        let result = try extract([
            { var entry = TestZipEntry("a//./b.txt", "zip64"); entry.zip64 = true; return entry }()
        ])
        #expect(result.readableFiles.map(\.entryPath) == ["a/b.txt"])
        #expect(contents(of: "\(root)/a/b.txt") == "zip64")
    }

    @Test func removesLeftoversOfPreviousAttempt() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("前の依頼".utf8).write(to: destination.appending(path: "old.txt"))
        let result = try extract([TestZipEntry("new.txt", "今の依頼")])
        #expect(result.readableFiles.map(\.entryPath) == ["new.txt"])
        #expect(!FileManager.default.fileExists(atPath: "\(root)/old.txt"))
    }

    @Test func extractsEmptyZipAsEmptyContents() throws {
        let result = try extract([])
        #expect(result.readableFiles.isEmpty)
        #expect(result.materials.isEmpty)
        #expect(result.skippedEntries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: root))
    }

    // MARK: - 展開しない項目

    @Test func skipsUnsafeNamesWithoutWritingOutsideDestination() throws {
        let id = UUID().uuidString
        let absolute = directory.appending(path: "absolute-\(id).txt").path(percentEncoded: false)
        let result = try extract([
            TestZipEntry("../escape-\(id).txt", "x"),
            TestZipEntry("a/../../escape2-\(id).txt", "x"),
            TestZipEntry(absolute, "x"),
            TestZipEntry("C:\\escape.txt", "x"),
            TestZipEntry("D:escape.txt", "x"),
            TestZipEntry("dir\\..\\escape.txt", "x"),
            TestZipEntry("bad\u{01}name.txt", "x"),
            TestZipEntry("line\nbreak.txt", "x"),
            // Shift_JIS の「あ.txt」
            TestZipEntry(bytes: [0x82, 0xA0, 0x2E, 0x74, 0x78, 0x74], Data("x".utf8)),
            TestZipEntry("./", ""),
            // `/` や `\` の直後の結合文字（U+0301）で 1 つの文字にまとまっても、バイトの `/`・`\` で区切る
            TestZipEntry("../\u{301}escape3-\(id).txt", "x"),
            TestZipEntry("./../\u{301}d-\(id)/f", "x"),
            TestZipEntry("/\u{301}x-\(id)", "x"),
            TestZipEntry("a\\\u{301}x", "x"),
            // 結合文字で始まる要素は、展開先の下の安全な名前として展開する（展開先の外と見誤らない）
            TestZipEntry("dir/\u{301}ok.txt", "combining"),
            TestZipEntry("ok.txt", "safe")
        ])

        #expect(result.skippedEntries.map(\.reason) == [
            .parentDirectory, .parentDirectory, .absolutePath, .backslashOrDrive, .backslashOrDrive, .backslashOrDrive,
            .controlCharacter, .controlCharacter, .unreadableName, .emptyName,
            .parentDirectory, .parentDirectory, .absolutePath, .backslashOrDrive
        ])
        // 一覧の名前には制御文字と読めないバイトを出さない
        #expect(result.skippedEntries[6].entryPath == "bad\u{FFFD}name.txt")
        #expect(result.skippedEntries[8].entryPath == "\u{FFFD}\u{FFFD}.txt")
        #expect(result.readableFiles.map(\.entryPath) == ["dir/\u{301}ok.txt", "ok.txt"])
        #expect(contents(of: "\(root)/dir/\u{301}ok.txt") == "combining")
        #expect(filesOutsideDestination().isEmpty)
        let parent = directory.deletingLastPathComponent()
        let parentPath = parent.path(percentEncoded: false)
        #expect(!FileManager.default.fileExists(atPath: "\(parentPath)\u{301}escape3-\(id).txt"))
        #expect(!FileManager.default.fileExists(atPath: "\(parentPath)\u{301}d-\(id)"))
        #expect(!FileManager.default.fileExists(atPath: "/\u{301}x-\(id)"))
        // 親のディレクトリに、この試行の名前のものが何も無い
        let leaked = try FileManager.default.contentsOfDirectory(atPath: parentPath).filter { $0.contains(id) }
        #expect(leaked.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "escape-\(id).txt").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "escape2-\(id).txt").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: absolute))
    }

    @Test func skipsSymbolicLinksAndSpecialFiles() throws {
        let result = try extract([
            TestZipEntry("link", "../../../etc/passwd", unixMode: 0o120777),
            TestZipEntry("pipe", "", unixMode: 0o010644),
            // UNIX 以外で作った zip の外部属性は種類として読まない
            { var entry = TestZipEntry("dos.txt", "dos", unixMode: 0o120777); entry.hostSystem = 0; return entry }()
        ])
        #expect(result.skippedEntries.map(\.reason) == [.symbolicLink, .specialFile])
        #expect(result.readableFiles.map(\.entryPath) == ["dos.txt"])
        #expect(!FileManager.default.fileExists(atPath: "\(root)/link"))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: "\(root)/link")) == nil)
    }

    /// 作成元が OS X（19）の zip も、外部属性の上位 16 ビットを UNIX のモードとして読む
    @Test func skipsSymbolicLinkFromOSXHost() throws {
        var link = TestZipEntry("link", "../..", unixMode: 0o120755)
        link.hostSystem = 19
        var file = TestZipEntry("file.txt", "ok")
        file.hostSystem = 19
        let result = try extract([link, file])
        #expect(result.skippedEntries == [.init(entryPath: "link", reason: .symbolicLink)])
        #expect(result.readableFiles.map(\.entryPath) == ["file.txt"])
        #expect(!FileManager.default.fileExists(atPath: "\(root)/link"))
    }

    @Test func skipsSymbolicLinkMadeByZipCommand() throws {
        let source = directory.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(String(repeating: "deflate me ", count: 100).utf8).write(to: source.appending(path: "a.txt"))
        let link = source.appending(path: "link").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "../..")
        try #require(run("/usr/bin/zip", ["-q", "--symlinks", archive.path(percentEncoded: false), "a.txt", "link"], in: source) == 0)
        try FileManager.default.removeItem(at: source)

        let result = try AttachmentZipExtractor().extract(zipAt: archive, to: destination)
        #expect(result.readableFiles.map(\.entryPath) == ["a.txt"])
        #expect(result.skippedEntries == [.init(entryPath: "link", reason: .symbolicLink)])
        #expect(contents(of: "\(root)/a.txt") == String(repeating: "deflate me ", count: 100))
    }

    /// Finder の「圧縮」と同じ `ditto -c -k` の zip（データディスクリプタ付きの Deflate・ディレクトリの項目）も読める
    @Test func extractsZipMadeByDitto() throws {
        let source = directory.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source.appending(path: "画像"), withIntermediateDirectories: true)
        try Data(String(repeating: "素材の説明\n", count: 100).utf8).write(to: source.appending(path: "画像/説明.md"))
        try Data("{}".utf8).write(to: source.appending(path: "tokens.json"))
        let parent = directory.path(percentEncoded: false)
        let arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", "assets", archive.path(percentEncoded: false)]
        try #require(run("/usr/bin/ditto", arguments, in: directory) == 0)
        try FileManager.default.removeItem(at: source)

        let result = try AttachmentZipExtractor().extract(zipAt: archive, to: destination)
        #expect(result.readableFiles.map(\.entryPath).sorted() == ["assets/tokens.json", "assets/画像/説明.md"])
        #expect(contents(of: "\(root)/assets/画像/説明.md") == String(repeating: "素材の説明\n", count: 100))
        #expect(!FileManager.default.fileExists(atPath: "\(parent)assets"))
    }

    @Test func skipsEncryptedAndUnsupportedCompression() throws {
        var encrypted = TestZipEntry("secret.txt", "????")
        encrypted.flags = 0x0001
        let result = try extract([encrypted, TestZipEntry("bzip2.txt", "BZh", method: 12), TestZipEntry("plain.txt", "ok")])
        #expect(result.skippedEntries.map(\.reason) == [.encrypted, .unsupportedCompression(method: 12)])
        #expect(result.readableFiles.map(\.entryPath) == ["plain.txt"])
        #expect(!FileManager.default.fileExists(atPath: "\(root)/secret.txt"))
    }

    @Test func skipsMacOSMetadata() throws {
        let result = try extract([
            .directory("__MACOSX/"),
            TestZipEntry("__MACOSX/dir/._b.txt", "resource fork"),
            TestZipEntry(".DS_Store", "finder"),
            TestZipEntry("dir/._b.txt", "apple double"),
            TestZipEntry("dir/b.txt", "本物")
        ])
        #expect(result.skippedEntries.map(\.reason) == Array(repeating: .macOSMetadata, count: 4))
        #expect(result.readableFiles.map(\.entryPath) == ["dir/b.txt"])
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root).sorted() == ["dir", "dir/b.txt"])
    }

    @Test func skipsEntriesThatConflictWithWrittenPaths() throws {
        let result = try extract([
            TestZipEntry("a.txt", "first"),
            TestZipEntry("a.txt", "second"),
            TestZipEntry("x", "file"),
            TestZipEntry("x/y.txt", "under a file")
        ])
        #expect(result.skippedEntries == [.init(entryPath: "a.txt", reason: .conflict), .init(entryPath: "x/y.txt", reason: .conflict)])
        #expect(contents(of: "\(root)/a.txt") == "first")
    }

    /// APFS（既定）は大文字小文字と Unicode の正規化を区別しないので、違いがそれだけの名前は後のものを飛ばす（`O_EXCL` の `EEXIST`）
    @Test func skipsEntriesThatDifferOnlyInCaseOrNormalization() throws {
        let composed = "\u{304C}.txt"
        let decomposed = "\u{304B}\u{3099}.txt"
        let result = try extract([
            TestZipEntry("A.txt", "first"),
            TestZipEntry("a.txt", "second"),
            TestZipEntry(composed, "NFC"),
            TestZipEntry(decomposed, "NFD"),
            TestZipEntry("Docs", "file"),
            TestZipEntry("docs/x.txt", "under a file")
        ])
        #expect(result.skippedEntries.map(\.reason) == [.conflict, .conflict, .conflict])
        // `String` の `==` は正規化の違いを同じとみなすので、バイト列で比べる
        let skipped = result.skippedEntries.map { Array($0.entryPath.utf8) }
        #expect(skipped == [Array("a.txt".utf8), Array(decomposed.utf8), Array("docs/x.txt".utf8)])
        #expect(result.readableFiles.map(\.entryPath) == ["A.txt", composed])
        #expect(contents(of: "\(root)/A.txt") == "first")
        #expect(contents(of: "\(root)/\(composed)") == "NFC")
        #expect(result.materials.map(\.entryPath) == ["Docs"])
    }
}

// MARK: - 合計の上限・zip でない・展開した後の確かめ

extension AttachmentZipExtractorTests {
    @Test func rejectsWhenDeclaredSizeExceedsLimitBeforeWriting() throws {
        try expectError(
            .declaredTooLarge(bytes: 12, limit: 10),
            [TestZipEntry("a.txt", "123456"), TestZipEntry("b.txt", "123456")],
            limits: .init(maxTotalBytes: 10)
        )
    }

    @Test func countsOnlyFilesToExtractAgainstFileLimit() throws {
        let limits = AttachmentZipExtractor.Limits(maxFileCount: 2)
        let three = [TestZipEntry("a.txt"), TestZipEntry("b.txt"), TestZipEntry("c.txt")]
        try expectError(.tooManyFiles(count: 3, limit: 2), three, limits: limits)
        // ディレクトリと展開しない項目は数えない
        let result = try extract(
            [.directory("d/"), TestZipEntry("d/a.txt"), TestZipEntry("._a.txt"), TestZipEntry("../c.txt"), TestZipEntry("b.txt")],
            limits: limits
        )
        #expect(result.readableFiles.count == 2)
    }

    @Test func rejectsTooManyDirectoriesBeforeWriting() throws {
        let limits = AttachmentZipExtractor.Limits(maxDirectoryCount: 2)
        // ディレクトリの項目と、ファイルの親（a・b・c・c/d）を数える
        try expectError(
            .tooManyDirectories(count: 4, limit: 2),
            [.directory("a/"), TestZipEntry("b/x.txt"), TestZipEntry("c/d/y.txt")],
            limits: limits
        )
        // 同じパスは 1 つと数え、展開しない項目のディレクトリは数えない
        let result = try extract(
            [.directory("a/"), TestZipEntry("a/x.txt"), .directory("a/b/"), TestZipEntry("a/b/y.txt"), TestZipEntry("__MACOSX/z/._y.txt")],
            limits: limits
        )
        #expect(result.readableFiles.map(\.entryPath) == ["a/x.txt", "a/b/y.txt"])
    }

    @Test func removesExtractionWhenActualSizeExceedsLimit() throws {
        // 宣言値は 10 バイトだが、実際は 1,000 バイトに展開される（上限は 100 バイト）
        var bomb = TestZipEntry("bomb.txt", String(repeating: "a", count: 1_000), method: 8)
        bomb.declaredSize = 10
        try expectError(.extractedTooLarge(limit: 100), [TestZipEntry("first.txt", "kept?"), bomb], limits: .init(maxTotalBytes: 100))
    }

    @Test func rejectsSizeOrChecksumThatDoesNotMatchDeclaration() throws {
        var larger = TestZipEntry("larger.txt", String(repeating: "b", count: 50), method: 8)
        larger.declaredSize = 10
        try expectError(.corrupted(reason: "展開した大きさが宣言と合いません"), [larger])

        var checksum = TestZipEntry("checksum.txt", "content")
        checksum.declaredCRC = 0
        try expectError(.corrupted(reason: "CRC-32 が合いません"), [checksum])
    }

    // MARK: - zip でない・壊れた zip

    @Test func rejectsFileThatIsNotZip() throws {
        try Data("これは zip ではない".utf8).write(to: archive)
        #expect(throws: AttachmentZipError.notZip) {
            try AttachmentZipExtractor().extract(zipAt: archive, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    @Test func rejectsCentralDirectoryOutOfRange() throws {
        var data = try TestZip.build([TestZipEntry("a.txt", "a")])
        // 中央ディレクトリの終わりの「中央ディレクトリの位置」を、ファイルの外にする
        let offset = data.count - 22 + 16
        data.replaceSubrange(offset..<(offset + 4), with: [0xFF, 0xFF, 0xFF, 0x00])
        try data.write(to: archive)
        #expect(throws: AttachmentZipError.corrupted(reason: "中央ディレクトリの位置が合いません")) {
            try AttachmentZipExtractor().extract(zipAt: archive, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    @Test func rejectsTruncatedDeflateData() throws {
        var data = try TestZip.build([TestZipEntry("a.txt", String(repeating: "abc", count: 200), method: 8)])
        // ローカルファイルヘッダ（30 バイト + 名前 5 バイト）の後ろの Deflate の中身を 0 で潰す
        data.replaceSubrange(35..<45, with: Data(count: 10))
        try data.write(to: archive)
        let error = #expect(throws: AttachmentZipError.self) {
            try AttachmentZipExtractor().extract(zipAt: archive, to: destination)
        }
        guard case .corrupted = error else {
            Issue.record("壊れた zip として断っていません: \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    @Test func refusesDestinationThatContainsArchive() throws {
        try TestZip.build([TestZipEntry("a.txt", "a")]).write(to: archive)
        #expect(throws: AttachmentZipError.destinationContainsArchive) {
            try AttachmentZipExtractor().extract(zipAt: archive, to: directory)
        }
        #expect(FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)))
    }

    @Test func refusesDestinationThatIsArchiveItself() throws {
        try TestZip.build([TestZipEntry("a.txt", "a")]).write(to: archive)
        #expect(throws: AttachmentZipError.destinationContainsArchive) {
            try AttachmentZipExtractor().extract(zipAt: archive, to: archive)
        }
        // シンボリックリンクを解決すると同じパスになる場合も断る
        let alias = directory.appending(path: "alias.zip").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: archive.path(percentEncoded: false))
        #expect(throws: AttachmentZipError.destinationContainsArchive) {
            try AttachmentZipExtractor().extract(zipAt: URL(fileURLWithPath: alias), to: archive)
        }
        #expect(FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)))
    }

    // MARK: - 展開した後の確かめ

    @Test func verificationFindsSymbolicLinkAndExcessFiles() throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("12345".utf8).write(to: destination.appending(path: "a.txt"))
        try Data("12345".utf8).write(to: destination.appending(path: "b.txt"))
        #expect(throws: AttachmentZipError.tooManyFiles(count: 2, limit: 1)) {
            try AttachmentZipExtractor.verify(root: root, limits: .init(maxFileCount: 1))
        }
        #expect(throws: AttachmentZipError.extractedTooLarge(limit: 9)) {
            try AttachmentZipExtractor.verify(root: root, limits: .init(maxTotalBytes: 9))
        }
        try AttachmentZipExtractor.verify(root: root, limits: .init(maxTotalBytes: 10, maxFileCount: 2))
        try FileManager.default.createDirectory(at: destination.appending(path: "sub"), withIntermediateDirectories: true)
        #expect(throws: AttachmentZipError.tooManyDirectories(count: 1, limit: 0)) {
            try AttachmentZipExtractor.verify(root: root, limits: .init(maxDirectoryCount: 0))
        }

        let link = "\(root)/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: directory.path(percentEncoded: false))
        let error = #expect(throws: AttachmentZipError.self) {
            try AttachmentZipExtractor.verify(root: root, limits: .default)
        }
        #expect(error == .unsafeExtraction(path: "link"))
    }
}
