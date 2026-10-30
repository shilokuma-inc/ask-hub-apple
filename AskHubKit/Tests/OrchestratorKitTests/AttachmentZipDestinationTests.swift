import Foundation
@testable import OrchestratorKit
import Testing

/// テストのパスの道具
enum TestPath {
    /// リンクを解いた形（`/var` は `/private/var`）。`URL.resolvingSymlinksInPath()` は `/private` を外すので `realpath(3)` を使う
    static func real(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else {
            return path
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

// MARK: - extract-zip の展開先の確かめ（Issue #771 の第三者レビュー）

struct AttachmentZipDestinationTests {
    /// テストの一時ディレクトリ（リンクを解いた形）。ホームもこの中に作る
    private let directory: String
    private let home: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "askhub-zip-destination-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = TestPath.real(url.path(percentEncoded: false))
        home = "\(directory)/home.d"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    private func resolve(_ path: String) throws(AttachmentZipDestination.Refusal) -> String {
        try AttachmentZipDestination.resolve(path, homes: [home])
    }

    private func expectRefused(_ path: String, _ reasonPrefix: String) {
        do {
            let resolved = try resolve(path)
            Issue.record("断られずに \(resolved) になりました")
        } catch {
            #expect(error.reason.hasPrefix(reasonPrefix), "\(error.reason)")
        }
    }

    @Test func acceptsAbsoluteDotDPathAndResolvesLinksAndTrailingSlashes() throws {
        #expect(try resolve("\(directory)/u/x.zip.d") == "\(directory)/u/x.zip.d")
        #expect(try resolve("\(directory)/u/x.zip.d//") == "\(directory)/u/x.zip.d")
        // 一時ディレクトリの /var のリンクも解く
        let unresolved = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        if TestPath.real(unresolved) != unresolved {
            let name = (directory as NSString).lastPathComponent
            #expect(try resolve("\(unresolved)/\(name)/x.d") == "\(directory)/x.d")
        }
    }

    @Test func refusesRelativeDotAndControlCharacters() {
        expectRefused("x.zip.d", "展開先は絶対パスで指定してください")
        expectRefused("\(directory)/a/../x.d", "展開先に . か .. の要素があります")
        expectRefused("\(directory)/./x.d", "展開先に . か .. の要素があります")
        expectRefused("\(directory)/a\nfailed\tx.d", "展開先に制御文字があります")
    }

    @Test func refusesNamesNotEndingWithDotDAndRoot() {
        expectRefused("/", "展開先の名前は .d で終わるもの")
        expectRefused("\(directory)/out", "展開先の名前は .d で終わるもの")
        expectRefused("\(directory)/.d", "展開先の名前は .d で終わるもの")
    }

    @Test func refusesHomeAndAncestorsOfHome() throws {
        expectRefused(home, "展開先がホームかホームより上の階層です")
        let nested = "\(directory)/up.d/home"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        do {
            _ = try AttachmentZipDestination.resolve("\(directory)/up.d", homes: [nested])
            Issue.record("ホームより上の階層を断りませんでした")
        } catch {
            #expect(error.reason.hasPrefix("展開先がホームかホームより上の階層です"))
        }
    }

    @Test func refusesLinksThatPointElsewhere() throws {
        let fileManager = FileManager.default
        // 展開先そのものがリンク
        try fileManager.createSymbolicLink(atPath: "\(directory)/link.d", withDestinationPath: "\(directory)/u")
        expectRefused("\(directory)/link.d", "展開先がシンボリックリンクです")
        expectRefused("\(directory)/link.d/", "展開先がシンボリックリンクです")
        // 途中のリンクを解くとホームになる
        try fileManager.createSymbolicLink(atPath: "\(directory)/up", withDestinationPath: directory)
        expectRefused("\(directory)/up/home.d", "展開先がホームかホームより上の階層です")
        // 途中のリンクを解くと名前が .d でなくなる
        try fileManager.createDirectory(atPath: "\(directory)/plain", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: "\(directory)/alias.d", withDestinationPath: "\(directory)/plain")
        expectRefused("\(directory)/alias.d/sub", "展開先の名前は .d で終わるもの")
    }

    @Test func refusesInsideGitWorkTreeButNotGitDirectoryInsidePreviousExtraction() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: "\(directory)/repo/.git", withIntermediateDirectories: true)
        expectRefused("\(directory)/repo/sub/x.zip.d", "展開先が git のリポジトリの中です")
        // 前の展開の残りに zip の中の .git があっても、展開し直せる
        try fileManager.createDirectory(atPath: "\(directory)/u/x.zip.d/.git", withIntermediateDirectories: true)
        #expect(try resolve("\(directory)/u/x.zip.d") == "\(directory)/u/x.zip.d")
    }

    @Test func refusesWhenParentIsNotDirectory() throws {
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(directory)/file"))
        expectRefused("\(directory)/file/x.d", "展開先の親がディレクトリではありません")
    }
}
