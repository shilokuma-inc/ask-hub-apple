import AskHubProtocol
import Foundation

/// 最終 PR の段取りで、作業ブランチを扱う。
///
/// - 前の検証と直しは、epic の作業場所（同じ worktree）で作業ブランチを取り出し直す（DerivedData を使い回すため、パスを変えない）
/// - レビューと判断の仕分けは、ジョブのフォルダに head を取り出して読ませ、終わったら消す（常時オンの Mac に、ほかの epic の作業場所を残さない）
/// - push は fast-forward だけ（force push しない）
extension GitRepositoryWorkspace: FinalGit {
    public func checkOutEpic(
        _ repo: RepositoryFullName,
        epic: ULID,
        branches: FinalBranches
    ) async throws(WorkspaceError) -> CheckedOutEpic {
        guard EpicFile.isBranchName(branches.base), EpicFile.isBranchName(branches.epic) else {
            throw .failed("ブランチの名前（\(branches.base)・\(branches.epic)）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        let worktree = epicDirectory(repo, epic: epic)
        var checkedOut: CheckedOutEpic?
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            guard let head = try await commit(of: "refs/remotes/origin/\(branches.epic)", in: clone) else {
                throw .failed("作業ブランチ \(branches.epic) がリモートに無い")
            }
            try await place(branches.epic, at: "origin/\(branches.epic)", in: worktree, clone: clone)
            let facts = try await facts(from: branches.base, in: clone)
            checkedOut = CheckedOutEpic(repo: repo, directory: worktree, branches: branches, head: head, facts: facts)
        }
        guard let checkedOut else { throw .failed("作業ブランチを取り出せなかった") }
        return checkedOut
    }

    public func reuseEpic(_ repo: RepositoryFullName, epic: ULID, branches: FinalBranches) async throws(WorkspaceError) -> CheckedOutEpic? {
        guard EpicFile.isBranchName(branches.base), EpicFile.isBranchName(branches.epic) else {
            throw .failed("ブランチの名前（\(branches.base)・\(branches.epic)）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        let worktree = epicDirectory(repo, epic: epic)
        var reused: CheckedOutEpic?
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            guard try await isCheckedOut(branches.epic, in: worktree, clone: clone) else { return }
            try await update(clone, of: repo)
            markUsed(clone)
            let head = try await git(["rev-parse", "HEAD"], in: worktree)
            guard try await commit(of: "refs/remotes/origin/\(branches.epic)", in: clone) == head else { return }
            let facts = try await facts(from: branches.base, in: clone)
            reused = CheckedOutEpic(repo: repo, directory: worktree, branches: branches, head: head, facts: facts)
        }
        return reused
    }

    public func conflictedPaths(in epic: CheckedOutEpic) async throws(WorkspaceError) -> [String] {
        let names = try await git(["diff", "--name-only", "-z", "--diff-filter=U"], in: epic.directory)
        return names.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
    }

    public func commitAndPush(_ epic: CheckedOutEpic, message: String) async throws(WorkspaceError) -> String? {
        try await commitAndPush(epic.repo, worktree: epic.directory, branch: epic.branches.epic, what: "作業ブランチ", message: message)
    }

    public func mergeBase(into epic: CheckedOutEpic) async throws(WorkspaceError) -> [String]? {
        guard await isWorktree(epic.directory, of: cloneDirectory(of: epic.repo)) else {
            throw .failed("epic の作業場所の .git が、ワーカーの clone を指していない（書き換えられた）")
        }
        let base = "refs/remotes/origin/\(epic.branches.base)"
        // base がもう作業ブランチに入っている（GitHub のコンフリクトの判定が古かった）
        if try await gitIfFound(["merge-base", "--is-ancestor", base, "HEAD"], in: epic.directory) != nil { return nil }
        let identity = await identity(for: epic.repo)
        // コンフリクトすると終了コード 1。どちらでも、取り込みの途中（MERGE_HEAD がある）になっていることを確かめる
        let result = try await run(identity + ["merge", "--no-ff", "--no-commit", "--quiet", base], in: epic.directory)
        guard result.succeeded || (result.status == 1 && !result.timedOut && !result.terminatedBySignal) else {
            throw Self.classify(result, command: "merge")
        }
        guard try await gitIfFound(["rev-parse", "--quiet", "--verify", "MERGE_HEAD"], in: epic.directory) != nil else {
            throw .failed("base（\(epic.branches.base)）を作業ブランチに取り込めなかった")
        }
        return try await conflictedPaths(in: epic)
    }

    public func unresolvedConflicts(_ paths: [String], in epic: CheckedOutEpic) async -> [String] {
        paths.filter { path in
            // 読めない（消した・文字でない）ファイルには印が無い
            guard let data = FileManager.default.contents(atPath: epic.directory.appendingPathComponent(path).path),
                  let text = String(data: data, encoding: .utf8) else { return false }
            return Self.hasConflictMarkers(text)
        }
    }

    /// コンフリクトの印の行（`<<<<<<< HEAD`・`>>>>>>> <取り込んだもの>`）があるか。`=======` は Markdown の見出しにも使うので見ない
    static func hasConflictMarkers(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            ["<<<<<<<", ">>>>>>>"].contains { marker in line == marker || line.hasPrefix(marker + " ") }
        }
    }

    public func messages(
        after ancestor: String,
        upTo descendant: String,
        in epic: CheckedOutEpic
    ) async throws(WorkspaceError) -> [String]? {
        try await messages(after: ancestor, upTo: descendant, in: epic.directory)
    }

    /// `ancestor` の後から `descendant` までのコミットのメッセージ（新しい順）。`ancestor` が `descendant` の祖先でなければ nil
    func messages(after ancestor: String, upTo descendant: String, in directory: URL) async throws(WorkspaceError) -> [String]? {
        guard AttemptFile.isCommitSHA(ancestor), AttemptFile.isCommitSHA(descendant),
              try await gitIfFound(["merge-base", "--is-ancestor", ancestor, descendant], in: directory) != nil else {
            return nil
        }
        // メッセージの区切りに、メッセージに現れない NUL を使う
        let log = try await git(["log", "--format=%B%x00", "\(ancestor)..\(descendant)"], in: directory)
        return log.split(separator: "\0").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public func checkOutFinal(
        _ repo: RepositoryFullName,
        job: ULID,
        branches: FinalBranches,
        head: String?
    ) async throws(WorkspaceError) -> FinalReviewCheckout {
        guard EpicFile.isBranchName(branches.base), EpicFile.isBranchName(branches.epic), head.map(AttemptFile.isCommitSHA) ?? true else {
            throw .failed("ブランチの名前（\(branches.base)・\(branches.epic)）か head（\(head ?? "")）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        let worktree = jobDirectory(job).appendingPathComponent("repository/\(repo.name)", isDirectory: true)
        var (resolved, facts) = ("", "")
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            guard try await commit(of: "refs/remotes/origin/\(branches.base)", in: clone) != nil else {
                throw .failed("base \(branches.base) がリモートに無い")
            }
            guard let commit = try await commit(of: head ?? "refs/remotes/origin/\(branches.epic)", in: clone) else {
                throw .failed(head.map { "head \($0) がリモートに無い" } ?? "作業ブランチ \(branches.epic) がリモートに無い")
            }
            resolved = commit
            // 前の試行の写しが残っていれば作り直す
            try remove(worktree)
            try await git(["worktree", "prune"], in: clone)
            try createDirectory(worktree.deletingLastPathComponent())
            try await git(["worktree", "add", "--detach", "--force", worktree.path, commit], in: clone)
            facts = try await self.facts(from: branches.base, in: clone)
        }
        return try await finalDiff(in: worktree, base: branches.base, head: resolved, facts: facts)
    }

    public func mergeBase(_ repo: RepositoryFullName, branches: FinalBranches, head: String) async throws(WorkspaceError) -> String {
        guard EpicFile.isBranchName(branches.base), AttemptFile.isCommitSHA(head) else {
            throw .failed("base（\(branches.base)）か head（\(head)）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        var base = ""
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            guard try await commit(of: head, in: clone) != nil else { throw .failed("head \(head) がリモートに無い") }
            base = try await git(["merge-base", "refs/remotes/origin/\(branches.base)", head], in: clone)
        }
        guard AttemptFile.isCommitSHA(base) else { throw .failed("base \(branches.base) と \(head) の分岐点を読めない") }
        return base
    }

    public func checkOutCommit(_ repo: RepositoryFullName, job: ULID, commit: String, name: String) async throws(WorkspaceError) -> URL {
        guard AttemptFile.isCommitSHA(commit), name.wholeMatch(of: #/[a-z]+/#) != nil else {
            throw .failed("コミット（\(commit)）か置き場所の名前（\(name)）の形が違う")
        }
        let clone = cloneDirectory(of: repo)
        let worktree = jobDirectory(job).appendingPathComponent("\(name)/\(repo.name)", isDirectory: true)
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            guard try await self.commit(of: commit, in: clone) != nil else { throw .failed("コミット \(commit) がリモートに無い") }
            // 前の試行の写しが残っていれば作り直す
            try remove(worktree)
            try await git(["worktree", "prune"], in: clone)
            try createDirectory(worktree.deletingLastPathComponent())
            try await git(["worktree", "add", "--detach", "--force", worktree.path, commit], in: clone)
        }
        return worktree
    }

    /// base との分岐点から `head` までの差分（base に後から入った変更を含めない）。差分の外部のコマンド・変換は使わない
    private func finalDiff(
        in worktree: URL,
        base: String,
        head: String,
        facts: String
    ) async throws(WorkspaceError) -> FinalReviewCheckout {
        let range = "origin/\(base)...\(head)"
        let options = ["--no-color", "--no-ext-diff", "--no-textconv"]
        let diff = try await git(["diff"] + options + [range], in: worktree)
        let stat = try await git(["diff", "--stat", "--no-color", range], in: worktree)
        // 名前を変えたものを、消したものと足したものに分けて、元と先の両方のパスを得る
        let names = try await git(["diff", "--name-only", "-z", "--no-renames", range], in: worktree)
        let project = try await git(["diff", "-U0", "--no-renames"] + options + [range, "--", "*.pbxproj"], in: worktree)
        return FinalReviewCheckout(
            directory: worktree,
            head: head,
            diff: diff,
            stat: stat,
            paths: names.split(separator: "\0").map(String.init).filter { !$0.isEmpty },
            projectLines: Self.changedLines(in: project),
            facts: facts
        )
    }

    /// `git diff -U0` の出力のうち、足した行と消した行（ファイルの見出しの `+++`・`---` を除く）
    static func changedLines(in diff: String) -> [String] {
        diff.split(separator: "\n").map(String.init).filter { line in
            (line.hasPrefix("+") || line.hasPrefix("-")) && !line.hasPrefix("+++") && !line.hasPrefix("---")
        }
    }

    public func removeEpic(_ repo: RepositoryFullName, epic: ULID, branch: String) async throws(WorkspaceError) {
        guard EpicFile.isBranchName(branch) else { throw .failed("作業ブランチの名前（\(branch)）の形が違う") }
        let clone = cloneDirectory(of: repo)
        // `epics/<epic>` の下には、この epic の作業場所と、人がする作業で渡されたファイルだけを置く
        let folder = setup.root.appendingPathComponent("epics/\(epic.rawValue)", isDirectory: true)
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try remove(folder)
            guard FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path) else { return }
            try await git(["worktree", "prune"], in: clone)
            // 作業ブランチと子ブランチ（`<作業ブランチ>-<タスク>`）だけを消す。epic の id は長さが決まっているので、ほかの epic のものに当たらない
            let refs = try await git(["for-each-ref", "--format=%(refname)", "refs/heads/\(branch)", "refs/heads/\(branch)-*"], in: clone)
            for ref in refs.split(separator: "\n") where ref == "refs/heads/\(branch)" || ref.hasPrefix("refs/heads/\(branch)-") {
                try await git(["update-ref", "-d", String(ref)], in: clone)
            }
        }
    }
}
