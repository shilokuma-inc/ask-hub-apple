@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// 本物の git で、手元のベアのリポジトリを origin にして、最終 PR の段取りの git の操作を確かめる（作り方は `TaskGitTests`）
struct FinalGitTests {
    static let repo = TaskGitTests.repo
    static let epic = TaskGitTests.epic
    static let branches = FinalBranches(base: "develop", epic: TaskGitTests.branches.epic)
    static let job = ULID(rawValue: "01JCJ0C0000000000000000001")!

    let base = TaskGitTests()

    @Test func fixesOnWorkBranchAndFindsOwnCommit() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await base.makeWorkspace()
        let epic = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        #expect(epic.head == (try base.remoteHead(Self.branches.epic)))
        #expect(epic.facts == "- Swift 6 で書く")
        #expect(epic.directory == workspace.epicDirectory(Self.repo, epic: Self.epic))
        // 変更が無ければコミットも push もしない
        #expect(try await workspace.commitAndPush(epic, message: "何もしない") == nil)

        try "struct Ranking {}\n".write(to: epic.directory.appendingPathComponent("Ranking.swift"), atomically: true, encoding: .utf8)
        let trailer = "AskHub-Job: \(Self.job.rawValue)"
        let head = try #require(try await workspace.commitAndPush(epic, message: "最終 PR を直す\n\n\(trailer)"))
        #expect(try base.remoteHead(Self.branches.epic) == head)
        let messages = try #require(try await workspace.messages(after: epic.head, upTo: head, in: epic))
        #expect(messages.count == 1)
        #expect(messages.first?.contains(trailer) == true)
        // 祖先でなければ nil
        #expect(try await workspace.messages(after: head, upTo: epic.head, in: epic) == nil)

        // やり直しでは、手元の変更を捨ててリモートの先頭から取り出し直す
        try "leftover".write(to: epic.directory.appendingPathComponent("Leftover.swift"), atomically: true, encoding: .utf8)
        let again = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        #expect(again.head == head)
        #expect(!FileManager.default.fileExists(atPath: again.directory.appendingPathComponent("Leftover.swift").path))
    }

    @Test func checksOutWholeEpicDiffIntoJobFolder() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await base.makeWorkspace()
        // base に後から入った変更は、最終 PR の差分に含めない
        try base.shell("""
            cd '\(base.root.path)/seed' && echo later > Later.md && git add . && \
            git -c user.name=t -c user.email=t@example.invalid commit --quiet -m later && git push --quiet '\(base.origin.path)' develop
            """)
        let epic = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        let project = epic.directory.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "shellScript = \"swiftlint\";\n".write(to: project.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(
            at: epic.directory.appendingPathComponent("README.md"), to: epic.directory.appendingPathComponent("Docs.md")
        )
        let head = try #require(try await workspace.commitAndPush(epic, message: "プロジェクトを足す"))

        let review = try await workspace.checkOutFinal(Self.repo, job: Self.job, branches: Self.branches, head: nil)
        #expect(review.head == head)
        #expect(review.directory.path.contains("jobs/\(Self.job.rawValue)/repository"))
        #expect(review.diff.contains("shellScript"))
        #expect(!review.diff.contains("Later.md"))
        // 名前を変えたものは、元と先の両方のパスを持つ
        #expect(Set(review.paths) == ["App.xcodeproj/project.pbxproj", "Docs.md", "README.md"])
        #expect(review.projectLines == ["+shellScript = \"swiftlint\";"])
        #expect(review.facts == "- Swift 6 で書く")
        #expect(try base.shell("cd '\(review.directory.path)' && git rev-parse HEAD") == head)

        await workspace.release(Self.job)
        #expect(!FileManager.default.fileExists(atPath: review.directory.path))
    }

    @Test func removesOnlyThisEpicWorkspaceAndBranches() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await base.makeWorkspace()
        let task = try await workspace.checkOutTask(Self.repo, epic: Self.epic, branches: TaskGitTests.branches)
        let epic = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        #expect(task.directory == epic.directory)
        let clone = base.root.appendingPathComponent("work/repos/\(Self.repo.owner)/\(Self.repo.name)")
        // ほかの epic の作業ブランチ
        let other = "askhub/01JCJ0A0000000000000000009"
        try base.shell("cd '\(clone.path)' && git branch \(other) \(epic.head)")

        try await workspace.removeEpic(Self.repo, epic: Self.epic, branch: Self.branches.epic)
        #expect(!FileManager.default.fileExists(atPath: base.root.appendingPathComponent("work/epics/\(Self.epic.rawValue)").path))
        let branches = try base.shell("cd '\(clone.path)' && git for-each-ref --format='%(refname:short)' refs/heads/")
        let names = Set(branches.split(separator: "\n").map(String.init))
        #expect(!names.contains(Self.branches.epic))
        #expect(!names.contains(TaskGitTests.branches.task))
        #expect(names.contains(other))
        // リモートの作業ブランチには触れない
        #expect(try base.remoteHead(Self.branches.epic) == epic.head)
        // もう一度片付けても失敗しない
        try await workspace.removeEpic(Self.repo, epic: Self.epic, branch: Self.branches.epic)
    }
}
