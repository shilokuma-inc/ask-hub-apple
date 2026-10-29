import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - askhub-orchestrator extract-zip の出力（Issue #771）

struct AttachmentZipCommandTests {
    private let directory: URL
    private let archive: URL
    private let destination: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "askhub-zip-command-\(UUID().uuidString)", directoryHint: .isDirectory)
        archive = directory.appending(path: "in.zip", directoryHint: .notDirectory)
        destination = directory.appending(path: "in.zip.d", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `realpath(3)` で解かない、渡したままの展開先（末尾の `/` なし）
    private var root: String {
        String(destination.path(percentEncoded: false).dropLast())
    }

    private func run(_ entries: [TestZipEntry]) throws -> AttachmentZipCommand.Result {
        try TestZip.build(entries).write(to: archive)
        return AttachmentZipCommand.run(zipPath: archive.path(percentEncoded: false), destinationPath: root)
    }

    @Test func listsReadableFilesMaterialsAndSkippedEntriesAsTabSeparatedLines() throws {
        let result = try run([
            .directory("icons/"),
            TestZipEntry("icons/app.svg", "<svg/>"),
            TestZipEntry("README.md", "# 素材"),
            TestZipEntry("fonts/Brand.otf", "font"),
            TestZipEntry("../evil.txt", "x"),
            TestZipEntry("link", "/etc", unixMode: 0o120777),
            TestZipEntry("__MACOSX/._app.svg", "meta")
        ])
        #expect(result.status == 0)
        #expect(result.output == """
            extracted\t\(root)\t2\t1\t2
            readable\timage/svg+xml\t6\ticons/app.svg\t\(root)/icons/app.svg
            readable\ttext/markdown\t\("# 素材".utf8.count)\tREADME.md\t\(root)/README.md
            material\t4\tfonts/Brand.otf\t\(root)/fonts/Brand.otf
            skipped\t名前に .. があるため展開しませんでした\t../evil.txt
            skipped\tシンボリックリンクのため展開しませんでした\tlink

            """)
        #expect(FileManager.default.fileExists(atPath: "\(root)/icons/app.svg"))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "evil.txt").path(percentEncoded: false)))
    }

    @Test func emptyZipHasOnlySummaryLine() throws {
        let result = try run([])
        #expect(result.status == 0)
        #expect(result.output == "extracted\t\(root)\t0\t0\t0\n")
    }

    @Test func failsWithReasonWhenZipCannotBeExtracted() throws {
        try Data("not a zip".utf8).write(to: archive)
        let result = AttachmentZipCommand.run(zipPath: archive.path(percentEncoded: false), destinationPath: root)
        #expect(result.status == AttachmentZipCommand.failureStatus)
        #expect(result.output == "failed\t\(AttachmentZipError.notZip.message)\n")
        #expect(!FileManager.default.fileExists(atPath: root))
    }

    @Test func failsWhenZipIsMissing() {
        let result = AttachmentZipCommand.run(zipPath: archive.path(percentEncoded: false), destinationPath: root)
        #expect(result.status == AttachmentZipCommand.failureStatus)
        #expect(result.output.hasPrefix("failed\tzip を読めませんでした"))
        #expect(result.output.filter(\.isNewline).count == 1)
    }

    @Test func failsWhenDestinationContainsArchive() throws {
        try TestZip.build([TestZipEntry("a.txt", "a")]).write(to: archive)
        let result = AttachmentZipCommand.run(
            zipPath: archive.path(percentEncoded: false),
            destinationPath: directory.path(percentEncoded: false)
        )
        #expect(result.output == "failed\t\(AttachmentZipError.destinationContainsArchive.message)\n")
        #expect(FileManager.default.fileExists(atPath: archive.path(percentEncoded: false)))
    }

    @Test func sanitizesTabsNewlinesAndControlCharacters() {
        #expect(AttachmentZipCommand.sanitized("a\tb\nc\r\u{7F}\u{85}\u{2028}\u{2029}d") == "a b c     d")
        #expect(AttachmentZipCommand.sanitized("名前.svg") == "名前.svg")
        let contents = AttachmentZipContents(
            directory: "/x",
            readableFiles: [],
            materials: [],
            skippedEntries: [.init(entryPath: "a\tb", reason: .controlCharacter)]
        )
        #expect(AttachmentZipCommand.output(for: contents) == "extracted\t/x\t0\t0\t1\nskipped\t名前に制御文字があるため展開しませんでした\ta b\n")
    }
}
