@testable import AskHubCommander
import AskHubCommands
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

/// リモートのブランチと worktree を覚えて、作業場所の用意に要る git のコマンドだけに答える（本物の git は流さない）
final class RemoteGit: CommandRunning {
    struct State {
        var commands: [[String]] = []
        /// リモートのブランチ（名前 → 先頭のコミット）
        var remote: [String: String]
        /// 取り出した worktree（パス → ブランチと先頭のコミット）
        var worktrees: [String: (branch: String, head: String)] = [:]
        var pushFailure: String?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(remote: [String: String], pushFailure: String? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(remote: remote, pushFailure: pushFailure))
    }

    var commands: [[String]] { state.withLock { $0.commands } }
    var remote: [String: String] { state.withLock { $0.remote } }

    func run(_ command: Command) async throws -> CommandResult {
        let arguments = command.arguments
        let directory = command.workingDirectory.path
        return try state.withLock { state in
            state.commands.append(arguments)
            return try Self.answer(arguments, in: directory, state: &state)
        }
    }

    private static func answer(_ arguments: [String], in directory: String, state: inout State) throws -> CommandResult {
        let worktree = state.worktrees[directory]
        switch Array(arguments.prefix(2)) {
        case ["clone", "--filter=blob:none"]:
            try FileManager.default.createDirectory(atPath: arguments.last! + "/.git", withIntermediateDirectories: true)
        case ["rev-parse", "--verify"]:
            let reference = arguments[3].replacingOccurrences(of: "^{commit}", with: "")
            let name = reference.replacingOccurrences(of: "refs/remotes/origin/", with: "")
            return state.remote[name].map { result($0) } ?? result(status: 1)
        case ["worktree", "add"]:
            try add(arguments, state: &state)
        case ["push", "origin"]:
            if let failure = state.pushFailure ?? (worktree == nil ? notRepository : nil) { return result(status: 128, error: failure) }
            state.remote[worktree!.branch] = worktree!.head
        case ["symbolic-ref", "--quiet"]:
            return worktree.map { result("refs/heads/\($0.branch)") } ?? result(status: 1)
        case ["rev-parse", "HEAD"]:
            return worktree.map { result($0.head) } ?? result(status: 128, error: notRepository)
        default:
            break
        }
        return result()
    }

    private static let notRepository = "fatal: not a git repository"

    /// `worktree add --no-track -B <ブランチ> <パス> <取り出す元>`
    private static func add(_ arguments: [String], state: inout State) throws {
        let (branch, path, start) = (arguments[4], arguments[5], arguments[6].replacingOccurrences(of: "origin/", with: ""))
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/.git", contents: Data("gitdir: x".utf8))
        state.worktrees[path] = (branch, state.remote[start] ?? "")
    }

    private static func result(_ output: String = "", status: Int32 = 0, error: String = "") -> CommandResult {
        CommandResult(status: status, standardOutput: Data((output.isEmpty ? "" : output + "\n").utf8), standardError: Data(error.utf8))
    }
}

struct PrepareWorkspaceTests {
    static let repo = EpicHandlersTests.repo
    static let mac = MacName(rawValue: "macbook-a")!
    static let epic = ULID(rawValue: "01JCJ0A0000000000000000001")!
    static let job = ULID(rawValue: "01JCJ0B0000000000000000002")!
    static let now = EpicHandlersTests.now
    static let develop = String(repeating: "d", count: 40)
    static let pushed = String(repeating: "p", count: 40)
    static var branch: String { PrepareWorkspaceRunner.branch(of: epic) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrepareWorkspaceTests-\(UUID().uuidString)")

    func workspace(_ git: RemoteGit) -> GitRepositoryWorkspace {
        GitRepositoryWorkspace(setup: .init(root: root, credentialHelper: "!'/opt/askhub/askhub-worker' git-credential"), runner: git)
    }

    func steps(_ git: RemoteGit) -> [String] {
        git.commands.map { $0.prefix(2).joined(separator: " ") }
    }

    @Test func createsWorkBranchFromBaseAndPushesIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let git = RemoteGit(remote: ["develop": Self.develop])
        let prepared = try await workspace(git).prepareEpic(Self.repo, epic: Self.epic, branch: Self.branch, base: "develop")
        #expect(prepared.branch == "askhub/01JCJ0A0000000000000000001")
        #expect(prepared.head == Self.develop)
        #expect(prepared.directory.path.hasSuffix("epics/01JCJ0A0000000000000000001/repository/askhub-sandbox"))
        #expect(steps(git) == [
            "clone --filter=blob:none", "rev-parse --verify", "rev-parse --verify", "worktree prune", "worktree add", "push origin",
            "rev-parse HEAD"
        ])
        #expect(git.commands.contains(["worktree", "add", "--no-track", "-B", Self.branch, prepared.directory.path, "origin/develop"]))
        // force push しない（リモートに無いことを確かめてから作る）
        let push = try #require(git.commands.first { $0.first == "push" })
        #expect(push == ["push", "origin", "refs/heads/\(Self.branch):refs/heads/\(Self.branch)"])
        #expect(git.remote[Self.branch] == Self.develop)
    }

    @Test func reusesBranchAlreadyPushedWithoutRecreating() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let git = RemoteGit(remote: ["develop": Self.develop])
        let workspace = workspace(git)
        _ = try await workspace.prepareEpic(Self.repo, epic: Self.epic, branch: Self.branch, base: "develop")
        // push の後、記録する前に止まったやり直し: 手元とリモートが同じなら、取り出し直さず push もしない
        let before = git.commands.count
        let again = try await workspace.prepareEpic(Self.repo, epic: Self.epic, branch: Self.branch, base: "develop")
        #expect(again.head == Self.develop)
        let retried = git.commands.dropFirst(before).map { $0.prefix(2).joined(separator: " ") }
        #expect(retried == [
            "fetch --prune", "remote set-head", "rev-parse --verify", "symbolic-ref --quiet", "rev-parse HEAD", "rev-parse HEAD"
        ])
    }

    @Test func takesOverBranchFromLastPush() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // ほかの Mac から引き継いだ: リモートの作業ブランチの最後に push したところから取り出す（base からは作らない）
        let git = RemoteGit(remote: ["develop": Self.develop, Self.branch: Self.pushed])
        let prepared = try await workspace(git).prepareEpic(Self.repo, epic: Self.epic, branch: Self.branch, base: "develop")
        #expect(prepared.head == Self.pushed)
        let add = ["worktree", "add", "--no-track", "-B", Self.branch, prepared.directory.path, "origin/\(Self.branch)"]
        #expect(git.commands.contains(add))
        #expect(!git.commands.contains { $0.first == "push" })
    }

    @Test func failsWithoutBaseBranchOrWithUnsafeNames() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let git = RemoteGit(remote: [:])
        await #expect(throws: WorkspaceError.failed("作業ブランチを作る元のブランチ develop がリモートに無い")) {
            try await workspace(git).prepareEpic(Self.repo, epic: Self.epic, branch: Self.branch, base: "develop")
        }
        #expect(!git.commands.contains { $0.first == "push" || $0.prefix(2) == ["worktree", "add"] })
        // git の選択肢に読まれる名前は渡さない
        await #expect(throws: WorkspaceError.self) {
            try await workspace(git).prepareEpic(Self.repo, epic: Self.epic, branch: "--upload-pack=x", base: "develop")
        }
    }

    @Test func pushRefusedForPermissionIsAuthFailure() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = "remote: Permission denied\nfatal: unable to access: The requested URL returned error: 403"
        let git = RemoteGit(remote: ["develop": Self.develop], pushFailure: denied)
        let error = await #expect(throws: WorkspaceError.self) {
            try await workspace(git).prepareEpic(Self.repo, epic: Self.epic, branch: Self.branch, base: "develop")
        }
        #expect(error?.attemptFailure.failureClass == .authExpired)
    }

    // MARK: - ジョブ

    func epicFile(_ stage: EpicStage, branch: String? = nil) -> EpicFile {
        let time = Timestamp(Self.now)
        return EpicFile(
            id: Self.epic,
            repo: Self.repo,
            title: "ランキング",
            stage: stage,
            mac: Self.mac,
            branch: branch,
            createdAt: time,
            updatedAt: time
        )
    }

    func jobFile() -> JobFile {
        let time = Timestamp(Self.now)
        return JobFile(
            id: Self.job,
            kind: .prepareWorkspace,
            repo: Self.repo,
            epic: Self.epic,
            assignedMac: Self.mac,
            needs: .init(claude: false, build: false),
            state: .assigned,
            createdAt: time,
            updatedAt: time
        )
    }

    func runner(_ store: InMemoryStateStore, git: RemoteGit) -> PrepareWorkspaceRunner {
        PrepareWorkspaceRunner(context: CommanderContext(store: store, mac: Self.mac) { Self.now }, workspace: workspace(git))
    }

    func store(with epic: EpicFile) async throws -> InMemoryStateStore {
        let store = InMemoryStateStore()
        let files = StateFileStore(store: store)
        try await files.create(epic, at: StatePath.epic(Self.repo, Self.epic), message: "epic")
        try await files.create(jobFile(), at: StatePath.job(Self.repo, epic: Self.epic, job: Self.job), message: "job")
        return store
    }

    @Test func jobWritesWorkBranchToAttemptOutputs() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await store(with: epicFile(.running))
        let context = CommanderContext(store: store, mac: Self.mac) { Self.now }
        let git = RemoteGit(remote: ["develop": Self.develop])
        let worker = JobWorker(
            runner: JobDispatcher([.prepareWorkspace: runner(store, git: git)]),
            recorder: AttemptRecorder(files: context.files, mac: Self.mac) { Self.now }
        )
        let attempt = try #require(try await worker.perform(jobFile()))
        #expect(attempt.outcome == .succeeded)
        #expect(attempt.outputs == AttemptFile.Outputs(commit: Self.develop, branch: Self.branch))
        // epic.json は司令塔だけが書く（ワーカーは書かない）
        #expect(try await context.files.read(EpicFile.self, at: StatePath.epic(Self.repo, Self.epic))?.file.branch == nil)
    }

    @Test func jobUsesBranchWrittenInEpicAndSkipsEndedEpic() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let git = RemoteGit(remote: ["develop": Self.develop])
        let running = try await store(with: epicFile(.running, branch: "askhub/renamed"))
        #expect(try await runner(running, git: git).execute(jobFile()).outputs?.branch == "askhub/renamed")
        // 開始した後にやめた epic は用意しない（成功で終える）
        let abandoned = try await store(with: epicFile(.abandoned))
        let before = git.commands.count
        #expect(try await runner(abandoned, git: git).execute(jobFile()) == JobResult())
        #expect(git.commands.count == before)
    }

    @Test func jobCreatesWorkBranchFromBaseBranchOfRepository() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // repo.json の build.baseBranch から作業ブランチを作る（既定の develop ではなく）
        let store = try await store(with: epicFile(.running))
        let build = RepositoryFile.Build(
            baseBranch: "main",
            xcode: try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS]),
            childChecks: ["build / build"],
            finalChecks: ["build / build"]
        )
        let repository = RepositoryFile(repo: Self.repo, platform: .apple, build: build, addedAt: Timestamp(Self.now))
        try await StateFileStore(store: store).create(repository, at: StatePath.repository(Self.repo), message: "repo")
        let git = RemoteGit(remote: ["main": Self.develop])
        let result = try await runner(store, git: git).execute(jobFile())
        #expect(result.failure == nil)
        #expect(git.commands.contains { $0.prefix(2) == ["worktree", "add"] && $0.last == "origin/main" })
    }

    @Test func dispatcherRefusesKindsItDoesNotHandle() async throws {
        let dispatcher = JobDispatcher([.prepareWorkspace: StubJob { _ in JobResult() }])
        #expect(dispatcher.kinds == [.prepareWorkspace])
        var job = jobFile()
        job.kind = .implementTask
        #expect(try await dispatcher.execute(job).failure?.failureClass == .unexpected)
    }
}
