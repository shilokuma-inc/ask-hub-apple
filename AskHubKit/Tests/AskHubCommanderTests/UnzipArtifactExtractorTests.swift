@testable import AskHubCommander
import AskHubCommands
import Foundation
import Testing

/// artifact の zip を確かめて取り出す（macOS の zip・unzip を使う）
struct UnzipArtifactExtractorTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("artifact-tests-\(UUID().uuidString)", isDirectory: true)

    /// `files`（相対パス → 中身）と `links`（相対パス → 指す先）を置いて、zip にする
    private func zip(files: [String: Data], links: [String: String] = [:]) async throws -> Data {
        let source = root.appendingPathComponent("source", isDirectory: true)
        for (path, data) in files {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        for (path, target) in links {
            let file = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target)
        }
        let archive = root.appendingPathComponent("a.zip")
        let names = Array(files.keys) + Array(links.keys)
        let command = Command(
            executable: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-y", archive.path] + names.sorted(),
            workingDirectory: source,
            timeout: .seconds(60)
        )
        let result = try await ProcessCommandRunner().run(command)
        try #require(result.status == 0)
        return try Data(contentsOf: archive)
    }

    @Test func extractsPNGsByLocaleFolderInNameOrder() async throws {
        let png = commanderPNG()
        let data = try await zip(files: ["ja/02_quiz.png": png, "ja/01_main.png": png, "en/01_main.png": png])
        let folders = try await UnzipArtifactExtractor().extract(data, into: root.appendingPathComponent("out"))
        #expect(folders["ja"]?.map(\.lastPathComponent) == ["01_main.png", "02_quiz.png"])
        #expect(folders["en"]?.map(\.lastPathComponent) == ["01_main.png"])
        #expect(try Data(contentsOf: try #require(folders["ja"]?.first)) == png)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func refusesSymbolicLinks() async throws {
        let data = try await zip(files: ["ja/01_main.png": commanderPNG()], links: ["ja/02_link.png": "/etc/hosts"])
        await #expect(throws: ArtifactProblem.self) {
            try await UnzipArtifactExtractor().extract(data, into: root.appendingPathComponent("out"))
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func refusesFilesThatAreNotPNG() async throws {
        let data = try await zip(files: ["ja/01_main.png": Data("not a png".utf8)])
        await #expect(throws: ArtifactProblem("ja/01_main.png が PNG でない")) {
            try await UnzipArtifactExtractor().extract(data, into: root.appendingPathComponent("out"))
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func refusesEntriesOutsideTheLocaleFolders() async throws {
        let data = try await zip(files: ["ja/notes.txt": Data("x".utf8)])
        await #expect(throws: ArtifactProblem.self) {
            try await UnzipArtifactExtractor().extract(data, into: root.appendingPathComponent("out"))
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test(arguments: [
        ("ja/01_main.png", true), ("zh-Hans/01.main.png", true), ("../evil.png", false), ("/etc/evil.png", false),
        ("ja/../evil.png", false), ("ja/sub/01.png", false), ("ja/01.PNG", false), ("01.png", false), ("ja/.hidden.png", false)
    ])
    func checksEntryNames(_ name: String, _ valid: Bool) {
        #expect(UnzipArtifactExtractor.isEntry(name) == valid)
    }

    @Test func checksEveryEntryBeforeExtracting() throws {
        #expect(try UnzipArtifactExtractor.images(in: ["ja/", "ja/01.png", "en/01.png"]) == ["ja/01.png", "en/01.png"])
        // 言語の下のフォルダ・同じ名前の項目・画像の無い zip・多すぎる項目は断る
        #expect(throws: ArtifactProblem.self) { try UnzipArtifactExtractor.images(in: ["ja/", "ja/d00001/", "ja/01.png"]) }
        #expect(throws: ArtifactProblem("artifact に同じ名前の項目が 2 つ以上ある")) {
            try UnzipArtifactExtractor.images(in: ["ja/01.png", "ja/01.png"])
        }
        #expect(throws: ArtifactProblem("artifact に画像が無い")) { try UnzipArtifactExtractor.images(in: ["ja/"]) }
        let many = (0...UnzipArtifactExtractor.maximumEntries).map { "ja/\($0).png" }
        #expect(throws: ArtifactProblem.self) { try UnzipArtifactExtractor.images(in: many) }
    }

    @Test func readsTheExpandedSizeFromTheListing() {
        let listing = [
            "Archive:  a.zip",
            "  Length      Date    Time    Name",
            "---------  ---------- -----   ----",
            "   540055  11-12-2026 17:58   ja/02_quiz.png",
            "---------                     -------",
            "  4987593                     5 files"
        ]
        #expect(UnzipArtifactExtractor.expandedBytes(listing) == 4_987_593)
    }
}
