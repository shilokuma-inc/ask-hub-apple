import AskHubProtocol
import Foundation

/// epic の作業場所。clone はジョブの写しと同じものを使い、epic ごとの worktree に作業ブランチを取り出して、ジョブを超えて残す。
///
/// - 作業ブランチがリモートに無ければ、`origin/<base>` から作って push する（force push しない）
/// - リモートにあれば作り直さない。手元の作業場所がリモートと同じなら、そのまま使う（push の後、記録する前に止まったときのやり直し）。
///   違えば、最後に push したところから取り出し直す（ほかの Mac から引き継いだとき）
extension GitRepositoryWorkspace: EpicWorkspace {
    public func prepareEpic(
        _ repo: RepositoryFullName,
        epic: ULID,
        branch: String,
        base: String
    ) async throws(WorkspaceError) -> PreparedEpicWorkspace {
        guard EpicFile.isBranchName(branch), EpicFile.isBranchName(base) else {
            throw .failed("ブランチの名前（\(branch)・\(base)）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        let worktree = epicDirectory(repo, epic: epic)
        var head = ""
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            let remote = try await commit(of: "refs/remotes/origin/\(branch)", in: clone)
            if remote == nil, try await commit(of: "refs/remotes/origin/\(base)", in: clone) == nil {
                throw .failed("作業ブランチを作る元のブランチ \(base) がリモートに無い")
            }
            let current = await checkedOut(branch, in: worktree)
            if current == nil || (remote != nil && current != remote) {
                try remove(worktree)
                try await git(["worktree", "prune"], in: clone)
                try createDirectory(worktree.deletingLastPathComponent())
                let start = remote == nil ? "origin/\(base)" : "origin/\(branch)"
                try await git(["worktree", "add", "--no-track", "-B", branch, worktree.path, start], in: clone)
            }
            if remote == nil {
                // リモートに無いことを確かめてから作る。force push はしない（ほかで作られていれば断られ、次の試行でそれを使う）
                try await git(["push", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], in: worktree)
            }
            head = try await git(["rev-parse", "HEAD"], in: worktree)
        }
        return PreparedEpicWorkspace(directory: worktree, branch: branch, head: head)
    }

    /// epic の作業場所（`epics/<epic>/repository/<リポジトリの名前>`）。最終 PR のマージ後に消す
    public func epicDirectory(_ repo: RepositoryFullName, epic: ULID) -> URL {
        setup.root.appendingPathComponent("epics/\(epic.rawValue)/repository/\(repo.name)", isDirectory: true)
    }

    /// 参照の指すコミット。無ければ nil
    func commit(of reference: String, in clone: URL) async throws(WorkspaceError) -> String? {
        try await gitIfFound(["rev-parse", "--verify", "--quiet", "\(reference)^{commit}"], in: clone)
    }

    /// 作業場所に `branch` を取り出してあれば、その先頭のコミット。無い・別のブランチ・壊れている（取り出し直す）なら nil
    private func checkedOut(_ branch: String, in worktree: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".git").path),
              (try? await gitIfFound(["symbolic-ref", "--quiet", "HEAD"], in: worktree)) == "refs/heads/\(branch)" else {
            return nil
        }
        return try? await git(["rev-parse", "HEAD"], in: worktree)
    }
}
