import Foundation
@testable import OrchestratorKit
import Testing

/// 本物の `claude` は起動せず、`/bin/sh` などの無害なコマンドで確かめる
struct LocalLoopRuntimeTests {
    /// 一時ディレクトリの中に checkout と制御用 worktree を作る
    private func makeRepository() throws -> (RepositoryConfig, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalLoopRuntimeTests-\(UUID().uuidString)")
        let checkout = root.appendingPathComponent("ask-hub-apple")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        return (RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: checkout.path), root)
    }

    /// 条件が真になるまで最大 5 秒待つ
    private func waitUntil(_ condition: () async -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func readsStateFileInControlWorktree() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()
        #expect(await runtime.status(of: repository) == .idle)

        let stateFile = URL(fileURLWithPath: repository.controlWorktreePath).appendingPathComponent(LocalLoopRuntime.stateFileRelativePath)
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nactive: true\n---\n".utf8).write(to: stateFile)
        #expect(await runtime.status(of: repository) == LoopStatus(stateFileExists: true, processAlive: false))
    }

    @Test func reportsUnknownWhenControlWorktreeIsUnreadable() async throws {
        let (repository, root) = try makeRepository()
        let control = URL(fileURLWithPath: repository.controlWorktreePath)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: control.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: control.path)
            try? FileManager.default.removeItem(at: root)
        }

        // アクセス権が無いときは「無い」ではなく「確かめられない」
        #expect(await LocalLoopRuntime().status(of: repository) == LoopStatus(stateFileExists: nil, processAlive: false))
    }

    @Test func readsEpicSnapshotFromWorktree() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let control = URL(fileURLWithPath: repository.controlWorktreePath)
        let gitDirectory = root.appendingPathComponent("main.git/worktrees/ctl")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: control.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        // worktree の `.git` は gitdir を指すファイル
        try Data("gitdir: \(gitDirectory.path)\n".utf8).write(to: control.appendingPathComponent(".git"))
        try Data("ref: refs/heads/epic/mvp\n".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        try Data("- [x] A".utf8).write(to: control.appendingPathComponent(".claude/ralph-goal.local.md"))

        let snapshot = await LocalLoopRuntime().epicSnapshot(of: repository)
        #expect(snapshot == EpicSnapshot(branch: "epic/mvp", goal: "- [x] A", state: nil))

        // detached HEAD ではブランチが無い
        try Data("0123456789abcdef0123456789abcdef01234567\n".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        #expect(await LocalLoopRuntime().epicSnapshot(of: repository).branch == nil)
    }

    @Test func readsBranchFromGitDirectory() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = URL(fileURLWithPath: repository.checkoutPath)
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/develop\n".utf8).write(to: checkout.appendingPathComponent(".git/HEAD"))

        #expect(LocalLoopRuntime.currentBranch(of: checkout) == "develop")
        #expect(LocalLoopRuntime.currentBranch(of: root) == nil)
    }

    @Test func runsCommandInCheckoutAndTracksUntilExit() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()

        // 引数はシェルを経由せずに渡るので、空白を含んでも 1 つの引数のまま
        try await runtime.launch(["/bin/sh", "-c", #"pwd -P > out.txt; printf %s "$1" > arg.txt; sleep 1"#, "sh", "a b"], for: repository)
        #expect(await runtime.status(of: repository).processAlive)
        #expect(try await waitUntil { await !runtime.status(of: repository).processAlive })

        let checkout = URL(fileURLWithPath: repository.checkoutPath)
        let workingDirectory = try String(contentsOf: checkout.appendingPathComponent("out.txt"), encoding: .utf8)
        // 一時ディレクトリは /var → /private/var のシンボリックリンクを含むので、実体のパスで比べる
        let resolved = try #require(realpath(checkout.path, nil))
        defer { free(resolved) }
        #expect(workingDirectory.trimmingCharacters(in: .newlines) == String(cString: resolved))
        #expect(try String(contentsOf: checkout.appendingPathComponent("arg.txt"), encoding: .utf8) == "a b")
    }

    @Test func resolvesRelativeExecutableFromPath() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()

        try await runtime.launch(["touch", "launched"], for: repository)
        let marker = URL(fileURLWithPath: repository.checkoutPath).appendingPathComponent("launched")
        #expect(try await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
    }

    @Test func throwsWhenExecutableIsMissing() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalLoopRuntime()

        await #expect(throws: (any Error).self) {
            try await runtime.launch(["/nonexistent/start-loop"], for: repository)
        }
        #expect(await runtime.status(of: repository) == .idle)
    }
}
