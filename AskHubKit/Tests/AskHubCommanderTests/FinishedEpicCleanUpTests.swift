import AskHubBuild
@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

/// 終わった epic の、この Mac に残ったものの見回り。git は手元のベアのリポジトリ（作り方は `TaskGitTests`）、状態リポジトリはメモリの上に置く
struct FinishedEpicCleanUpTests {
    static let repo = TaskGitTests.repo
    /// 2 日前にマージした epic（常時オンの Mac で最終 PR を直して、作業場所と DerivedData が残った）
    static let merged = TaskGitTests.epic
    static let running = ULID(rawValue: "01JCJ0A0000000000000000002")!
    /// 1 時間前にマージした epic
    static let recent = ULID(rawValue: "01JCJ0A0000000000000000003")!
    /// 状態リポジトリに無い epic
    static let unknown = ULID(rawValue: "01JCJ0A0000000000000000004")!
    /// 3 日前にやめた epic（DerivedData だけが残った）
    static let abandoned = ULID(rawValue: "01JCJ0A0000000000000000005")!
    static let now = TaskJobFixture.start

    let base = TaskGitTests()
    let store = InMemoryStateStore()
    let locks = EpicLocks()
    let logs = OSAllocatedUnfairLock<[String]>(initialState: [])

    var builds: BuildDirectories { BuildDirectories(root: base.root.appendingPathComponent("builds")) }
    var clone: URL { base.root.appendingPathComponent("work/repos/\(Self.repo.owner)/\(Self.repo.name)") }

    func cleanUp(_ workspace: GitRepositoryWorkspace) -> FinishedEpicCleanUp {
        let context = CommanderContext(store: store, mac: TaskJobFixture.mac) { Self.now }
        return FinishedEpicCleanUp(context: context, workspace: workspace, builds: builds, locks: locks) { [logs] message in
            logs.withLock { $0.append(message) }
        }
    }

    /// 段階と、段階を変えてからの時間を指定して epic を置く
    func put(_ epic: ULID, _ stage: EpicStage, since age: TimeInterval) async throws {
        let time = Timestamp(Self.now.addingTimeInterval(-age))
        let file = EpicFile(
            id: epic,
            repo: Self.repo,
            title: "ランキング",
            stage: stage,
            mac: TaskJobFixture.mac,
            branch: PrepareWorkspaceRunner.branch(of: epic),
            createdAt: time,
            updatedAt: time
        )
        try await StateFileStore(store: store).create(file, at: StatePath.epic(Self.repo, epic), message: "epic")
    }

    /// 作業場所（作業ブランチと子ブランチ）と DerivedData を残した epic たちを置く
    func prepare() async throws -> GitRepositoryWorkspace {
        let workspace = try await base.makeWorkspace()
        _ = try await workspace.checkOutTask(Self.repo, epic: Self.merged, branches: TaskGitTests.branches)
        _ = try await workspace.checkOutEpic(Self.repo, epic: Self.merged, branches: FinalGitTests.branches)
        for epic in [Self.running, Self.recent] {
            _ = try await workspace.prepareEpic(Self.repo, epic: epic, branch: PrepareWorkspaceRunner.branch(of: epic), base: "develop")
        }
        for epic in [Self.merged, Self.running, Self.recent, Self.unknown, Self.abandoned] {
            try FileManager.default.createDirectory(at: builds.derivedData(for: epic), withIntermediateDirectories: true)
        }
        try await put(Self.merged, .merged, since: 2 * 24 * 60 * 60)
        try await put(Self.running, .running, since: 30 * 24 * 60 * 60)
        try await put(Self.recent, .merged, since: 60 * 60)
        try await put(Self.abandoned, .abandoned, since: 3 * 24 * 60 * 60)
        return workspace
    }

    func localBranches() throws -> Set<String> {
        let branches = try base.shell("cd '\(clone.path)' && git for-each-ref --format='%(refname:short)' refs/heads/")
        return Set(branches.split(separator: "\n").map(String.init))
    }

    @Test func removesOnlyEpicsFinishedLongEnoughAgo() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await prepare()
        #expect(workspace.epicsWithWorkspace() == [Self.merged, Self.running, Self.recent])

        await cleanUp(workspace).run()
        // マージから 1 日たった epic と、やめてから 1 日たった epic のものだけを消す
        #expect(workspace.epicsWithWorkspace() == [Self.running, Self.recent])
        #expect(builds.epics() == [Self.running, Self.recent, Self.unknown])
        let branches = try localBranches()
        #expect(!branches.contains(FinalGitTests.branches.epic))
        #expect(!branches.contains(TaskGitTests.branches.task))
        #expect(branches.contains(PrepareWorkspaceRunner.branch(of: Self.running)))
        #expect(branches.contains(PrepareWorkspaceRunner.branch(of: Self.recent)))
        // clone と、リモートの作業ブランチには触れない
        #expect(FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path))
        #expect(try base.remoteHead(FinalGitTests.branches.epic) != nil)
        let logged = logs.withLock { $0 }
        #expect(logged.count == 2)
        #expect(logged.allSatisfy { $0.contains("この Mac に残った作業場所と DerivedData を消した") })
        #expect(logged.contains { $0.contains(Self.merged.rawValue) })
        #expect(logged.contains { $0.contains(Self.abandoned.rawValue) })

        // もう一度見回っても、消すものは無い
        await cleanUp(workspace).run()
        #expect(logs.withLock { $0.count } == 2)
    }

    @Test func leavesEpicInUseByJobUntilNextRound() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await prepare()
        await locks.acquire(Self.merged)

        await cleanUp(workspace).run()
        // ジョブが使っている epic は、待たずに次の見回りに回す
        #expect(workspace.epicsWithWorkspace().contains(Self.merged))
        #expect(builds.epics().contains(Self.merged))
        #expect(!builds.epics().contains(Self.abandoned))
        #expect(await locks.waiting(for: Self.merged) == 0)

        await locks.release(Self.merged)
        await cleanUp(workspace).run()
        #expect(!workspace.epicsWithWorkspace().contains(Self.merged))
        #expect(!builds.epics().contains(Self.merged))
    }

    @Test func doesNothingWithoutLeftovers() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await base.makeWorkspace()
        try await put(Self.merged, .merged, since: 2 * 24 * 60 * 60)
        await cleanUp(workspace).run()
        #expect(logs.withLock { $0.isEmpty })
        #expect(try localBranches() == ["develop"])
    }
}
