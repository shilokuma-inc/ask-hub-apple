import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 中継のスクリプト（scripts/orchestrator/extract-attachment-zip.sh）の展開先の確かめ（Issue #771 の第三者レビュー）

/// 中継を `Process` で流し、断る条件を確かめる。`askhub-orchestrator` の代わりに `/bin/echo` を呼ばせ、渡されたパスを出させる。
/// ホーム・置き場所はテストの一時ディレクトリの中に差し替え、本物のホームやキャッシュには触れない
struct ExtractAttachmentZipScriptTests {
    /// このファイル（AskHubKit/Tests/OrchestratorKitTests/）から辿ったリポジトリの中継
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "scripts/orchestrator/extract-attachment-zip.sh")
        .path(percentEncoded: false)

    /// テストの一時ディレクトリ（リンクを解いた形）
    private let directory: String
    private let home: String
    /// 添付の置き場所（ASKHUB_ATTACHMENTS_DIR）
    private let root: String
    /// zip を置いた添付のディレクトリ（<置き場所>/<owner>/<repo>/discussion-1/<UUID>）
    private let attachment: String
    private let zip: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "askhub-zip-script-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = TestPath.real(url.path(percentEncoded: false))
        home = "\(directory)/home"
        root = "\(home)/attachments"
        attachment = "\(root)/owner/repo/discussion-1/u"
        zip = "\(attachment)/x.zip"
        try FileManager.default.createDirectory(atPath: attachment, withIntermediateDirectories: true)
        try Data("PK".utf8).write(to: URL(fileURLWithPath: zip))
    }

    private struct Run {
        let status: Int32
        let output: String
    }

    private func run(_ destination: String, root: String? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script, zip, destination]
        var environment = [
            "HOME": home,
            "PATH": "/usr/bin:/bin",
            "ASKHUB_ORCHESTRATOR": "/bin/echo",
            "ASKHUB_ATTACHMENTS_DIR": root ?? self.root
        ]
        // /usr/bin/git（xcrun の中継）が Xcode を見つけられるよう、指定があれば引き継ぐ
        environment["DEVELOPER_DIR"] = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(bytes: data, encoding: .utf8) ?? "")
    }

    /// 77 で断り、`failed` の 1 行だけを出し、`askhub-orchestrator`（echo）を呼ばない
    private func expectRefused(_ destination: String, root: String? = nil, _ reasonPrefix: String) throws {
        let result = try run(destination, root: root)
        #expect(result.status == 77, "\(result.output)")
        #expect(result.output.hasPrefix("failed\t\(reasonPrefix)"), "\(result.output)")
        #expect(result.output.filter(\.isNewline).count == 1, "\(result.output)")
    }

    @Test func passesResolvedDestinationInsideAttachmentsDirectory() throws {
        let expected = "extract-zip \(zip) \(attachment)/x.zip.d\n"
        #expect(try run("\(attachment)/x.zip.d").output == expected)
        // 末尾の / は落としてから渡す
        let trailing = try run("\(attachment)/x.zip.d/")
        #expect(trailing.status == 0)
        #expect(trailing.output == expected)
    }

    @Test func refusesRelativeDotsAndControlCharacters() throws {
        try expectRefused("x.zip.d", "展開先は絶対パスで指定してください")
        try expectRefused("\(attachment)/../u/x.zip.d", "展開先に . か .. の要素があります")
        try expectRefused("\(attachment)/a\nb.d", "展開先に制御文字があります")
        // 制御文字の確かめより前の理由（絶対パスでない）でも、値の改行で failed の次の行を足させない
        try expectRefused("x\nfailed\tinjected", "展開先は絶対パスで指定してください")
    }

    @Test func refusesOutsideAndNotDotD() throws {
        try FileManager.default.createDirectory(atPath: "\(directory)/outside", withIntermediateDirectories: true)
        try expectRefused("\(directory)/outside/x.zip.d", "展開先が添付の置き場所")
        try expectRefused("\(attachment)/x.zip.out", "展開先の名前は .d で終わるもの")
    }

    @Test func refusesLinksOutOfOrUpWithinAttachmentsDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: "\(directory)/outside", withIntermediateDirectories: true)
        // 途中のリンクで外へ出る
        try fileManager.createSymbolicLink(atPath: "\(attachment)/ext", withDestinationPath: "\(directory)/outside")
        try expectRefused("\(attachment)/ext/x.zip.d", "展開先が添付の置き場所")
        // 展開先そのものが置き場所の中の上の階層を指すリンク（ほかの添付ごと消える）
        try fileManager.createSymbolicLink(atPath: "\(attachment)/up.zip.d", withDestinationPath: "\(root)/owner")
        try expectRefused("\(attachment)/up.zip.d", "展開先がシンボリックリンクです")
        try expectRefused("\(attachment)/up.zip.d/", "展開先がシンボリックリンクです")
        // 途中のリンクを解くと名前が .d でなくなる
        try fileManager.createSymbolicLink(atPath: "\(attachment)/alias.d", withDestinationPath: "\(root)/owner")
        try expectRefused("\(attachment)/alias.d/repo", "展開先の名前は .d で終わるもの")
        #expect(fileManager.fileExists(atPath: zip))
    }

    @Test func refusesAttachmentsDirectoryAtOrAboveHome() throws {
        try expectRefused("\(attachment)/x.zip.d", root: home, "添付の置き場所がホームかホームより上の階層です")
        try expectRefused("\(attachment)/x.zip.d", root: directory, "添付の置き場所がホームかホームより上の階層です")
        try expectRefused("\(attachment)/x.zip.d", root: "/", "添付の置き場所がホームかホームより上の階層です")
    }

    @Test func refusesInsideGitWorkTree() throws {
        let repository = "\(directory)/repo"
        try FileManager.default.createDirectory(atPath: "\(repository)/attachments/u", withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", repository]
        git.standardOutput = FileHandle.nullDevice
        git.standardError = FileHandle.nullDevice
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        try expectRefused("\(repository)/attachments/u/x.zip.d", root: "\(repository)/attachments", "展開先が git のリポジトリの中です")
    }
}
