@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import os
import Testing

/// git のコマンドを記録し、worktree の追加では CLAUDE.md を置く（本物の git は流さない）
final class FakeGit: CommandRunning {
    private let state: OSAllocatedUnfairLock<(commands: [Command], failures: [String: CommandResult])>
    let claude: String?

    init(claude: String? = nil, failures: [String: CommandResult] = [:]) {
        self.claude = claude
        state = OSAllocatedUnfairLock(initialState: ([], failures))
    }

    var commands: [Command] { state.withLock { $0.commands } }

    func run(_ command: Command) async throws -> CommandResult {
        let failure = state.withLock { state in
            state.commands.append(command)
            return state.failures[command.arguments.first ?? ""]
        }
        if let failure {
            // 途中まで作ってから失敗した clone の残りを再現する
            if command.arguments.first == "clone", let path = command.arguments.last {
                let git = URL(fileURLWithPath: path).appendingPathComponent(".git")
                try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
            }
            return failure
        }
        if command.arguments.prefix(2) == ["worktree", "add"], let path = command.arguments.dropLast().last {
            let worktree = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
            if let claude { try Data(claude.utf8).write(to: worktree.appendingPathComponent("CLAUDE.md")) }
        }
        return CommandResult(status: 0, standardOutput: Data(), standardError: Data())
    }
}

struct GitRepositoryWorkspaceTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let job = ULID(rawValue: "01JCJ0B0000000000000000001")!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitRepositoryWorkspaceTests-\(UUID().uuidString)")

    func workspace(_ git: FakeGit) -> GitRepositoryWorkspace {
        GitRepositoryWorkspace(setup: .init(root: root, credentialHelper: "!'/opt/askhub/askhub-commander' git-credential"), runner: git)
    }

    @Test func clonesOnceAndAddsWorktreePerJob() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let git = FakeGit(claude: "# askhub\n\n## 全員向けの事実\nSwiftUI のアプリ\n\n## 人のセッション向けの手順\nPR を作る")
        let prepared = try await workspace(git).prepare(Self.repo, for: Self.job)
        #expect(prepared.directory.path.hasSuffix("jobs/\(Self.job.rawValue)/repository/askhub-sandbox"))
        #expect(prepared.facts == "SwiftUI のアプリ")
        let steps = git.commands.map { $0.arguments.prefix(2).joined(separator: " ") }
        #expect(steps == ["clone --filter=blob:none", "worktree prune", "worktree add"])
        let clone = try #require(git.commands.first)
        #expect(clone.arguments.contains("https://github.com/shilokuma-inc/askhub-sandbox.git"))
        #expect(git.commands.last?.arguments.last == "origin/HEAD")

        // 2 回目からは clone せず、fetch して既定のブランチを追う
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("repos/shilokuma-inc/askhub-sandbox/.git"), withIntermediateDirectories: true
        )
        let again = FakeGit()
        _ = try await workspace(again).prepare(Self.repo, for: Self.job)
        #expect(again.commands.map { $0.arguments.prefix(2).joined(separator: " ") } == [
            "fetch --prune", "remote set-head", "worktree prune", "worktree add"
        ])
    }

    @Test func gitRunsWithoutRepositoryHooksOrHumanSettings() throws {
        let environment = workspace(FakeGit()).environment
        var config: [String: String] = [:]
        for index in 0..<(Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0) {
            config[environment["GIT_CONFIG_KEY_\(index)"] ?? ""] = environment["GIT_CONFIG_VALUE_\(index)"]
        }
        #expect(config["core.hooksPath"] == "/dev/null")
        #expect(config["core.symlinks"] == "false")
        #expect(config["core.attributesFile"] == "/dev/null")
        #expect(config["core.excludesFile"] == "/dev/null")
        #expect(config["credential.helper"] == "!'/opt/askhub/askhub-commander' git-credential")
        // credential helper がリポジトリの持ち主でトークンを選べるよう、path を渡す
        #expect(config["credential.useHttpPath"] == "true")
        #expect(environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(environment["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
        // credential helper が Keychain を見つけられるよう、HOME は本当のホームフォルダのまま
        #expect(environment["HOME"] == FileManager.default.homeDirectoryForCurrentUser.path)
        // トークンは環境変数に置かない（credential helper が Keychain から読む）
        #expect(!environment.keys.contains { $0.contains("TOKEN") })
    }

    @Test func failuresAreClassified() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        func failed(_ message: String, timedOut: Bool = false) -> CommandResult {
            CommandResult(status: 128, standardOutput: Data(), standardError: Data(message.utf8), timedOut: timedOut)
        }
        let auth = "fatal: could not read Username for 'https://github.com': terminal prompts disabled"
        let cases: [(CommandResult, WorkspaceError.Kind)] = [
            (failed(auth), .unauthorized),
            (failed("fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com"), .unavailable),
            (failed("", timedOut: true), .unavailable),
            (failed("fatal: something else"), .failed)
        ]
        for (result, kind) in cases {
            do {
                _ = try await workspace(FakeGit(failures: ["clone": result])).prepare(Self.repo, for: Self.job)
                Issue.record("失敗しなかった")
            } catch {
                #expect(error.kind == kind)
            }
        }
        // 失敗した clone の残りは消す
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("repos/shilokuma-inc/askhub-sandbox").path))
    }

    @Test func jobsGetSeparateCopies() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(FakeGit())
        let other = ULID(rawValue: "01JCJ0B0000000000000000002")!
        let first = try await workspace.prepare(Self.repo, for: Self.job)
        let second = try await workspace.prepare(Self.repo, for: other)
        #expect(first.directory != second.directory)
        // 片方を片付けても、もう片方の写しは残る
        await workspace.release(Self.job)
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        #expect(FileManager.default.fileExists(atPath: second.directory.path))
        // リポジトリの名前が attachments でも、写しと添付の置き場所は重ならない
        let named = RepositoryFullName(rawValue: "shilokuma-inc/attachments")!
        let copy = try await workspace.prepare(named, for: other)
        #expect(copy.directory != (try await workspace.attachmentsDirectory(for: other)))
    }

    @Test func removesClonesUnusedForAWeek() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(FakeGit())
        let fileManager = FileManager.default
        let now = Date()
        for (name, age) in [("old", 8.0), ("recent", 1.0)] {
            let git = root.appendingPathComponent("repos/shilokuma-inc/\(name)/.git")
            try fileManager.createDirectory(at: git, withIntermediateDirectories: true)
            let marker = git.appendingPathComponent("askhub-last-used")
            fileManager.createFile(atPath: marker.path, contents: Data())
            try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-age * 24 * 60 * 60)], ofItemAtPath: marker.path)
        }
        // 古くても、ジョブの写しが残っている clone は消さない
        let busy = root.appendingPathComponent("repos/shilokuma-inc/busy/.git")
        let record = busy.appendingPathComponent("worktrees/busy")
        let worktree = root.appendingPathComponent("jobs/J/repository/busy")
        try fileManager.createDirectory(at: record, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        fileManager.createFile(atPath: worktree.appendingPathComponent(".git").path, contents: Data())
        try Data(worktree.appendingPathComponent(".git").path.utf8).write(to: record.appendingPathComponent("gitdir"))
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 24 * 60 * 60)], ofItemAtPath: busy.path)
        await workspace.removeUnusedClones(now: now)
        #expect(!fileManager.fileExists(atPath: root.appendingPathComponent("repos/shilokuma-inc/old").path))
        #expect(fileManager.fileExists(atPath: root.appendingPathComponent("repos/shilokuma-inc/recent").path))
        #expect(fileManager.fileExists(atPath: root.appendingPathComponent("repos/shilokuma-inc/busy").path))
    }

    @Test func releaseRemovesJobFolder() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = workspace(FakeGit())
        let attachments = try await workspace.attachmentsDirectory(for: Self.job)
        #expect(FileManager.default.fileExists(atPath: attachments.path))
        await workspace.release(Self.job)
        #expect(!FileManager.default.fileExists(atPath: workspace.jobDirectory(Self.job).path))
    }
}

/// 対象のリポジトリの事実の取り出し
struct RepositoryFactsTests {
    @Test func usesFactsSectionWhenPresent() {
        let text = """
        # アプリ

        ## 全員向けの事実
        - SwiftUI
        ```
        ## コードの中の見出しは区切りにしない
        ```
        ### 細かい事実

        ## 人のセッション向けの手順
        - PR を作る
        """
        #expect(RepositoryFacts.extract(from: text) == "- SwiftUI\n```\n## コードの中の見出しは区切りにしない\n```\n### 細かい事実")
    }

    @Test func followsFencesAndHeadingForms() {
        let text = """
        ##    全員向けの事実 ##
        - SwiftUI
        ````
        ```
        ## 4 つの囲みの中の 3 つは閉じではない
        ````
        ~~~
        ## チルダの囲みの中
        ~~~
           ## 人のセッション向けの手順
        - PR を作る
        """
        #expect(RepositoryFacts.extract(from: text) == "- SwiftUI\n````\n```\n## 4 つの囲みの中の 3 つは閉じではない\n````\n~~~\n## チルダの囲みの中\n~~~")
    }

    @Test func usesWholeFileWithoutSectionAndCapsLength() {
        #expect(RepositoryFacts.extract(from: "# アプリ\n\nSwiftUI のアプリ\n") == "# アプリ\n\nSwiftUI のアプリ")
        let long = String(repeating: "あ", count: RepositoryFacts.maximumLength + 10)
        let capped = RepositoryFacts.extract(from: long)
        #expect(capped.hasPrefix(String(repeating: "あ", count: RepositoryFacts.maximumLength)))
        #expect(capped.hasSuffix("省いた）"))
    }
}

extension WorkspaceError {
    /// 種類だけを比べる（説明の文は比べない）
    enum Kind: Equatable {
        case unavailable, unauthorized, failed
    }

    var kind: Kind {
        switch self {
        case .unavailable: .unavailable
        case .unauthorized: .unauthorized
        case .failed: .failed
        }
    }
}
