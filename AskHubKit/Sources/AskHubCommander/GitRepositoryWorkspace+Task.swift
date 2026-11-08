import AskHubProtocol
import Foundation

/// タスクの子ブランチを、epic の作業場所（`epicDirectory`）で扱う。
///
/// - 子ブランチは、同じ worktree で取り出し直す（DerivedData を epic の間で使い回すため、作業場所のパスを変えない）
/// - 前の試行が残した手元の変更と、無視されていない新しいファイルは捨てる（`checkout --force`・`clean -ffd`）
/// - コミットする前に、作業場所の `.git` がこの clone の worktree を指したままかを確かめる（Claude は作業場所のファイルを書き換えられるため）
/// - push は fast-forward だけ（force push しない）。リモートが動いていれば断られ、次の試行で取り出し直す
extension GitRepositoryWorkspace: TaskGit {
    /// ワーカーが作るコミットの書き手。`.invalid` は誰のものにもならないドメイン（RFC 2606）なので、GitHub の誰かのアカウントに結び付かない
    static let committerName = "AskHub"
    static let committerEmail = "worker@askhub.invalid"

    public func checkOutTask(
        _ repo: RepositoryFullName,
        epic: ULID,
        branches: TaskBranches
    ) async throws(WorkspaceError) -> CheckedOutTask {
        guard [branches.base, branches.epic, branches.task].allSatisfy(EpicFile.isBranchName) else {
            throw .failed("ブランチの名前（\(branches.base)・\(branches.epic)・\(branches.task)）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        let worktree = epicDirectory(repo, epic: epic)
        var checkedOut: CheckedOutTask?
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            guard let base = try await commit(of: "refs/remotes/origin/\(branches.epic)", in: clone) else {
                throw .failed("作業ブランチ \(branches.epic) がリモートに無い（作業場所の用意がまだ）")
            }
            let remote = try await commit(of: "refs/remotes/origin/\(branches.task)", in: clone)
            try await place(branches.task, at: "origin/\(remote == nil ? branches.epic : branches.task)", in: worktree, clone: clone)
            let head = try await git(["rev-parse", "HEAD"], in: worktree)
            let facts = try await facts(from: branches.base, in: clone)
            checkedOut = CheckedOutTask(
                repo: repo, directory: worktree, branches: branches, head: head, remoteHead: remote, base: base, facts: facts
            )
        }
        guard let checkedOut else { throw .failed("子ブランチを取り出せなかった") }
        return checkedOut
    }

    public func commitAndPush(_ task: CheckedOutTask, message: String) async throws(WorkspaceError) -> String? {
        try await commitAndPush(task.repo, worktree: task.directory, branch: task.branches.task, what: "子ブランチ", message: message)
    }

    /// epic の作業場所の手元の変更をすべてコミットし、`branch` を push して新しい先頭を返す。変更が無ければ nil。`what` はブランチの呼び名
    func commitAndPush(
        _ repo: RepositoryFullName,
        worktree: URL,
        branch: String,
        what: String,
        message: String
    ) async throws(WorkspaceError) -> String? {
        guard await isWorktree(worktree, of: cloneDirectory(of: repo)) else {
            throw .failed("epic の作業場所の .git が、ワーカーの clone を指していない（書き換えられた）")
        }
        guard try await gitIfFound(["symbolic-ref", "--quiet", "HEAD"], in: worktree) == "refs/heads/\(branch)" else {
            throw .failed("epic の作業場所が、\(what) \(branch) を取り出したままになっていない")
        }
        try await git(["add", "--all"], in: worktree)
        guard try await !git(["status", "--porcelain"], in: worktree).isEmpty else { return nil }
        let identity = ["-c", "user.name=\(Self.committerName)", "-c", "user.email=\(Self.committerEmail)"]
        try await git(identity + ["commit", "--quiet", "--no-verify", "--no-gpg-sign", "-m", message], in: worktree)
        let head = try await git(["rev-parse", "HEAD"], in: worktree)
        // push はリモートの追跡の参照（共有の clone）も書き換えるので、fetch と並ばないようにする
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await git(["push", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], in: worktree)
        }
        return head
    }

    public func isAncestor(_ ancestor: String, of descendant: String, in task: CheckedOutTask) async throws(WorkspaceError) -> Bool {
        guard AttemptFile.isCommitSHA(ancestor), AttemptFile.isCommitSHA(descendant) else { return false }
        // 祖先でなければ終了コード 1（`gitIfFound` は nil を返す）
        return try await gitIfFound(["merge-base", "--is-ancestor", ancestor, descendant], in: task.directory) != nil
    }

    public func checkOutReview(
        _ repo: RepositoryFullName,
        epic: ULID,
        branches: TaskBranches,
        head: String
    ) async throws(WorkspaceError) -> ReviewCheckout {
        guard EpicFile.isBranchName(branches.base), EpicFile.isBranchName(branches.epic), AttemptFile.isCommitSHA(head) else {
            throw .failed("ブランチの名前（\(branches.base)・\(branches.epic)）か head（\(head)）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        let worktree = epicDirectory(repo, epic: epic)
        var facts = ""
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            guard try await commit(of: head, in: clone) != nil else { throw .failed("子 PR の head \(head) がリモートに無い") }
            try await place(nil, at: head, in: worktree, clone: clone)
            facts = try await self.facts(from: branches.base, in: clone)
        }
        // 作業ブランチとの分岐点からの差分（作業ブランチに後から入った変更を含めない）。差分の外部のコマンド・変換は使わない
        let range = "origin/\(branches.epic)...\(head)"
        let diff = try await git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", range], in: worktree)
        let stat = try await git(["diff", "--stat", "--no-color", range], in: worktree)
        return ReviewCheckout(directory: worktree, diff: diff, stat: stat, facts: facts)
    }

    /// 人がする作業で渡されたファイルを置くフォルダ（`epics/<epic>/handover/<タスク>`）。作業場所と一緒に、最終 PR のマージ後に消える
    public func handoverDirectory(epic: ULID, task: String) async throws(WorkspaceError) -> URL {
        // タスクの id（`t1` など）はパスに使うので、英小文字と数字だけを受け付ける
        guard !task.isEmpty, task.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
            throw .failed("タスクの id（\(task)）の形が違う")
        }
        let directory = setup.root.appendingPathComponent("epics/\(epic.rawValue)/handover/\(task)", isDirectory: true)
        try remove(directory)
        try createDirectory(directory)
        return directory
    }

    /// base の CLAUDE.md から読んだリポジトリの事実。base に CLAUDE.md が無ければ空
    func facts(from base: String, in clone: URL) async throws(WorkspaceError) -> String {
        let revision = "refs/remotes/origin/\(base)"
        guard try await commit(of: revision, in: clone) != nil,
              try await !git(["ls-tree", "--name-only", revision, "--", "CLAUDE.md"], in: clone).isEmpty else { return "" }
        return RepositoryFacts.extract(from: try await git(["show", "\(revision):CLAUDE.md"], in: clone))
    }

    /// epic の作業場所に、`start` を `branch` として（nil ならブランチに乗せずに）取り出す。作業場所が無い・壊れていれば作り直す
    func place(_ branch: String?, at start: String, in worktree: URL, clone: URL) async throws(WorkspaceError) {
        if await isWorktree(worktree, of: clone) {
            let target = branch.map { ["--no-track", "-B", $0] } ?? ["--detach"]
            try await git(["checkout", "--force", "--quiet"] + target + [start], in: worktree)
        } else {
            try remove(worktree)
            try await git(["worktree", "prune"], in: clone)
            try createDirectory(worktree.deletingLastPathComponent())
            let target = branch.map { ["--no-track", "-B", $0] } ?? ["--detach"]
            try await git(["worktree", "add"] + target + [worktree.path, start], in: clone)
        }
        try await git(["clean", "-ffd", "--quiet"], in: worktree)
    }

    /// 作業場所の git が、この clone の worktree として使えるか（`.git` のファイルが別の場所を指すように書き換えられていないか）
    func isWorktree(_ worktree: URL, of clone: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: worktree.appendingPathComponent(".git").path),
              let common = try? await gitIfFound(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: worktree) else {
            return false
        }
        return Self.realPath(common) == Self.realPath(clone.appendingPathComponent(".git").path)
    }

    /// シンボリックリンクをたどった絶対パス（`/var` と `/private/var` をそろえる）
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
