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

    @Test func mergesBaseIntoWorkBranchAndFindsConflicts() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await base.makeWorkspace()
        // 作業ブランチと base が、同じファイルを別々に変える
        let epic = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        try "# 作業ブランチの App\n".write(to: epic.directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let mine = try #require(try await workspace.commitAndPush(epic, message: "作業ブランチで変える"))
        try base.shell("""
            cd '\(base.root.path)/seed' && echo '# base の App' > README.md && echo later > Later.md && git add . && \
            git -c user.name=t -c user.email=t@example.invalid commit --quiet -m base && git push --quiet '\(base.origin.path)' develop
            """)
        let fresh = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        #expect(fresh.head == mine)
        let conflicts = try #require(try await workspace.mergeBase(into: fresh))
        #expect(conflicts == ["README.md"])
        #expect(await workspace.unresolvedConflicts(conflicts, in: fresh) == ["README.md"])
        try "# 作業ブランチと base の App\n".write(to: fresh.directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(await workspace.unresolvedConflicts(conflicts, in: fresh).isEmpty)
        let merged = try #require(try await workspace.commitAndPush(fresh, message: "base を取り込む"))
        #expect(try base.remoteHead(Self.branches.epic) == merged)
        // マージのコミット（親が 2 つ）で、コンフリクトしなかった base の変更も入る
        let parents = try base.shell("git -C '\(base.origin.path)' rev-list --parents -n 1 \(merged)")
        #expect(parents.split(separator: " ").count == 3)
        #expect(FileManager.default.fileExists(atPath: fresh.directory.appendingPathComponent("Later.md").path))
        // base がもう入っているので、次は何もしない
        let again = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        #expect(try await workspace.mergeBase(into: again) == nil)
    }

    @Test func reusesWorkspaceWithMergeInProgress() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await base.makeWorkspace()
        #expect(try await workspace.reuseEpic(Self.repo, epic: Self.epic, branches: Self.branches) == nil)
        let epic = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        try "# 作業ブランチの App\n".write(to: epic.directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let mine = try #require(try await workspace.commitAndPush(epic, message: "作業ブランチで変える"))
        try base.shell("""
            cd '\(base.root.path)/seed' && echo '# base の App' > README.md && git add . && \
            git -c user.name=t -c user.email=t@example.invalid commit --quiet -m base && git push --quiet '\(base.origin.path)' develop
            """)
        let fresh = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        #expect(try await workspace.mergeBase(into: fresh) == ["README.md"])

        // コンフリクトの解消の途中で質問して止めた。取り込みの途中のまま使い、解消していないファイルを読み直せる
        let reused = try #require(try await workspace.reuseEpic(Self.repo, epic: Self.epic, branches: Self.branches))
        #expect(reused.head == mine)
        #expect(try await workspace.conflictedPaths(in: reused) == ["README.md"])
        try "# 作業ブランチと base の App\n".write(to: reused.directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        #expect(await workspace.unresolvedConflicts(["README.md"], in: reused).isEmpty)
        let merged = try #require(try await workspace.commitAndPush(reused, message: "base を取り込む"))
        let parents = try base.shell("git -C '\(base.origin.path)' rev-list --parents -n 1 \(merged)")
        #expect(parents.split(separator: " ").count == 3)
        #expect(try await workspace.conflictedPaths(in: reused).isEmpty)
    }

    @Test func mergesBaseWithoutConflicts() async throws {
        defer { try? FileManager.default.removeItem(at: base.root) }
        let workspace = try await base.makeWorkspace()
        try base.shell("""
            cd '\(base.root.path)/seed' && echo later > Later.md && git add . && \
            git -c user.name=t -c user.email=t@example.invalid commit --quiet -m later && git push --quiet '\(base.origin.path)' develop
            """)
        let epic = try await workspace.checkOutEpic(Self.repo, epic: Self.epic, branches: Self.branches)
        #expect(try await workspace.mergeBase(into: epic)?.isEmpty == true)
        let merged = try #require(try await workspace.commitAndPush(epic, message: "base を取り込む"))
        #expect(try base.remoteHead(Self.branches.epic) == merged)
    }

    @Test func findsOnlyConflictMarkerLines() {
        #expect(GitRepositoryWorkspace.hasConflictMarkers("a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> refs/remotes/origin/develop\n"))
        #expect(GitRepositoryWorkspace.hasConflictMarkers("<<<<<<<\n"))
        // Markdown の見出しの下線や、行の途中の記号は印でない
        #expect(!GitRepositoryWorkspace.hasConflictMarkers("見出し\n=======\n本文 <<<<<<< ではない\n"))
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
