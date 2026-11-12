@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

/// アイコンの元の選び方と、clone からの取り出し
struct AppIconLocatorTests {
    static let sha = String(repeating: "a", count: 40)

    static func tree(_ path: String, _ sha: String = Self.sha) -> AppIconLocator.Source {
        AppIconLocator.Source(path: path, tree: sha)
    }

    @Test func prefersAppIconComposerThenAssetCatalogThenShallowerOnes() {
        let trees = [
            Self.tree("App/Assets.xcassets/AppIcon.appiconset"),
            Self.tree("App/Icons/AppIcon-Neon.icon"),
            Self.tree("App/AppIcon.icon"),
            Self.tree("Widget/AppIcon.icon")
        ]
        #expect(AppIconLocator.choose(trees)?.path == "App/AppIcon.icon")
        #expect(AppIconLocator.choose(Array(trees.prefix(2)))?.path == "App/Assets.xcassets/AppIcon.appiconset")
        #expect(AppIconLocator.choose([Self.tree("A/B/Other.appiconset"), Self.tree("A/Other.appiconset")])?.path == "A/Other.appiconset")
        #expect(AppIconLocator.choose([Self.tree("App/Assets.xcassets"), Self.tree("App/AppIcon.iconset")]) == nil)
    }

    @Test func ignoresDependenciesTestsAndPreviews() {
        let trees = [
            Self.tree("Pods/Some/AppIcon.icon"),
            Self.tree("AppTests/Fixtures/AppIcon.icon"),
            Self.tree("App/Preview Content/Preview Assets.xcassets/AppIcon.appiconset"),
            Self.tree("App/Assets.xcassets/AppIcon-Beta.appiconset")
        ]
        #expect(AppIconLocator.choose(trees)?.path == "App/Assets.xcassets/AppIcon-Beta.appiconset")
    }

    @Test func readsTreeListing() {
        let other = String(repeating: "b", count: 40)
        let listing = [
            "040000 tree \(Self.sha)\tApp",
            "040000 tree \(other)\tApp/AppIcon.icon",
            "040000 tree not-a-sha\tApp/Broken.icon",
            "garbage"
        ].joined(separator: "\0")
        #expect(AppIconLocator.choose(fromTreeListing: listing) == Self.tree("App/AppIcon.icon", other))
        #expect(AppIconLocator.choose(fromTreeListing: "") == nil)
    }

    @Test func readsBlobsWithSizesAndSkipsLinksAndSubmodules() {
        let listing = [
            "100644 blob \(Self.sha)     120\ticon.json",
            "100755 blob \(Self.sha)    3000\tAssets/a b.svg",
            "120000 blob \(Self.sha)      11\tAssets/link.svg",
            "160000 commit \(Self.sha)       -\tVendor"
        ].joined(separator: "\0")
        #expect(AppIconLocator.blobs(fromListing: listing) == [
            AppIconLocator.Blob(path: "icon.json", sha: Self.sha, size: 120),
            AppIconLocator.Blob(path: "Assets/a b.svg", sha: Self.sha, size: 3000)
        ])
        #expect(AppIconLocator.blobs(fromListing: "100644 blob \(Self.sha)  1\t../outside.png") == nil)
        #expect(AppIconLocator.blobs(fromListing: "100644 blob \(Self.sha)  1\tAssets//a.png") == nil)
    }
}

/// 本物の git で、手元のベアのリポジトリを origin にして確かめる（`TaskGitTests` と同じ形）
struct GitAppIconTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitAppIconTests-\(UUID().uuidString)")
    var origin: URL { root.appendingPathComponent("origin.git") }

    /// アイコンの元を持つ origin と、ワーカーの clone を作る
    func makeWorkspace() throws -> GitRepositoryWorkspace {
        let seed = root.appendingPathComponent("seed")
        let icon = seed.appendingPathComponent("App/AppIcon.icon/Assets")
        let fixture = seed.appendingPathComponent("AppTests/AppIcon.icon")
        for directory in [icon, fixture] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(#"{"groups": []}"#.utf8).write(to: icon.deletingLastPathComponent().appendingPathComponent("icon.json"))
        try Data((0..<3000).map { UInt8($0 % 251) }).write(to: icon.appendingPathComponent("a b.png"))
        try FileManager.default.createSymbolicLink(atPath: icon.appendingPathComponent("link.png").path, withDestinationPath: "/etc/hosts")
        try Data("{}".utf8).write(to: fixture.appendingPathComponent("icon.json"))
        try shell("git init --quiet --bare --initial-branch=develop '\(origin.path)'")
        try shell("""
            cd '\(seed.path)' && git init --quiet --initial-branch=develop && git add . && \
            git -c user.name=t -c user.email=t@example.invalid commit --quiet -m init && git push --quiet '\(origin.path)' develop
            """)
        let work = root.appendingPathComponent("work")
        let clone = work.appendingPathComponent("repos/\(Self.repo.owner)/\(Self.repo.name)")
        try shell("git clone --quiet --no-checkout '\(origin.path)' '\(clone.path)'")
        let wrapper = root.appendingPathComponent("git")
        try "#!/bin/sh\nexec /usr/bin/git -c protocol.file.allow=always \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return GitRepositoryWorkspace(setup: .init(root: work, git: wrapper, credentialHelper: "!true"), runner: ProcessCommandRunner())
    }

    @discardableResult
    func shell(_ script: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw TaskGitTests.ShellFailure(output: text) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func locatesAndExportsIconFolderWithoutLinks() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        let source = try #require(try await workspace.locateAppIcon(Self.repo))
        #expect(source.path == "App/AppIcon.icon")
        #expect(source.tree == (try shell("git --git-dir='\(origin.path)' rev-parse develop:App/AppIcon.icon")))

        let destination = root.appendingPathComponent("export")
        let folder = try await workspace.exportAppIcon(source, of: Self.repo, to: destination)
        #expect(folder == destination.appendingPathComponent("AppIcon.icon", isDirectory: true))
        #expect(try Data(contentsOf: folder.appendingPathComponent("icon.json")) == Data(#"{"groups": []}"#.utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("Assets/a b.png")) == Data((0..<3000).map { UInt8($0 % 251) }))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Assets/link.png").path))
    }

    @Test func findsNothingWithoutIcon() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try makeWorkspace()
        try shell("""
            cd '\(root.appendingPathComponent("seed").path)' && git rm --quiet -r App && \
            git -c user.name=t -c user.email=t@example.invalid commit --quiet -m remove && git push --quiet '\(origin.path)' develop
            """)
        // テストのフォルダの下のアイコンは選ばない
        #expect(try await workspace.locateAppIcon(Self.repo) == nil)
    }
}
