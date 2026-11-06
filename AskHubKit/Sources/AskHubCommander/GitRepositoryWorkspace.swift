import AskHubCommands
import AskHubProtocol
import Foundation

/// 対象のリポジトリの写しを、ワーカー専用のフォルダに git で用意する（`docs/renewal/architecture.md` の「対象のリポジトリと clone」）。
///
/// - リポジトリごとに、中身を必要になるまで取らない clone（`--filter=blob:none --no-checkout`）を 1 つ持ち、使うたびに fetch する
/// - ジョブごとに、既定のブランチの最新を worktree で取り出す（並んで動くジョブの写しを分ける）。ジョブを終えたら消す
/// - リポジトリの中の設定を効かせない（hooks・シンボリックリンク・人の git の設定）。トークンは引数にも環境変数にも置かず、
///   credential helper（Keychain から読むコマンド）で git に渡す
public struct GitRepositoryWorkspace: RepositoryWorkspace {
    public struct Setup: Sendable {
        /// ワーカー専用のフォルダ（TCC の保護の外。`~/Library/Application Support/` の下など）
        public var root: URL
        public var git: URL
        /// git の `credential.helper` に渡すコマンド（GitHub のトークンを Keychain から読んで返す）
        public var credentialHelper: String
        /// git の 1 回のコマンドの時間の上限
        public var timeout: Duration

        public init(
            root: URL,
            git: URL = URL(fileURLWithPath: "/usr/bin/git"),
            credentialHelper: String,
            timeout: Duration = .seconds(10 * 60)
        ) {
            self.root = root
            self.git = git
            self.credentialHelper = credentialHelper
            self.timeout = timeout
        }
    }

    public var setup: Setup
    public var runner: any CommandRunning
    /// 同じリポジトリの clone を、並んで fetch・worktree の追加をしないように 1 つずつにする
    private let locks = RepositoryLocks()

    public init(setup: Setup, runner: any CommandRunning) {
        self.setup = setup
        self.runner = runner
    }

    public func prepare(_ repo: RepositoryFullName, for job: ULID) async throws(WorkspaceError) -> PreparedWorkspace {
        let clone = cloneDirectory(of: repo)
        // 添付（`attachments`）と重ならないよう、写しは `repository/` の下に置く
        let worktree = jobDirectory(job).appendingPathComponent("repository/\(repo.name)", isDirectory: true)
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            markUsed(clone)
            // 前の試行の写しが残っていれば作り直す
            try remove(worktree)
            try await git(["worktree", "prune"], in: clone)
            try await git(["worktree", "add", "--detach", "--force", worktree.path, "origin/HEAD"], in: clone)
        }
        let claude = try? String(contentsOf: worktree.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        return PreparedWorkspace(directory: worktree, facts: claude.map(RepositoryFacts.extract) ?? "")
    }

    public func attachmentsDirectory(for job: ULID) async throws(WorkspaceError) -> URL {
        let directory = jobDirectory(job).appendingPathComponent("attachments", isDirectory: true)
        try createDirectory(directory)
        return directory
    }

    /// ジョブのフォルダ（写しと添付）を消す。worktree の記録は、次に用意するときの `worktree prune` で消える
    public func release(_ job: ULID) async {
        try? remove(jobDirectory(job))
    }

    /// clone を最後に使ってから消すまでの日数（`docs/renewal/architecture.md` の「対象のリポジトリと clone」）
    public static let unusedCloneLifetime: TimeInterval = 7 * 24 * 60 * 60

    public func tidy() async {
        await removeUnusedClones(now: Date())
    }

    /// 最後に使ってから `unusedCloneLifetime` を過ぎた clone を消す。用意している間（リポジトリの排他の中）と、
    /// ジョブの写し（worktree）が残っている間は消さない
    func removeUnusedClones(now: Date) async {
        let owners = (try? FileManager.default.contentsOfDirectory(atPath: setup.root.appendingPathComponent("repos").path)) ?? []
        for owner in owners {
            let directory = setup.root.appendingPathComponent("repos/\(owner)")
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                guard let repo = RepositoryFullName(rawValue: "\(owner)/\(name)") else { continue }
                let clone = cloneDirectory(of: repo)
                try? await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
                    guard let used = lastUsed(clone), now.timeIntervalSince(used) > Self.unusedCloneLifetime,
                          !hasLiveWorktree(clone) else { return }
                    try remove(clone)
                }
            }
        }
    }

    /// clone を使った印（`.git` の中に置くので、写しには出ない）
    private func usedMarker(_ clone: URL) -> URL {
        clone.appendingPathComponent(".git/askhub-last-used")
    }

    private func markUsed(_ clone: URL) {
        FileManager.default.createFile(atPath: usedMarker(clone).path, contents: Data())
    }

    /// ジョブの写し（worktree）がまだ残っているか。git の worktree の記録（`.git/worktrees/<名前>/gitdir`）が指す先で見る
    private func hasLiveWorktree(_ clone: URL) -> Bool {
        let records = clone.appendingPathComponent(".git/worktrees")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: records.path)) ?? []
        return names.contains { name in
            let gitdir = records.appendingPathComponent("\(name)/gitdir")
            guard let path = try? String(contentsOf: gitdir, encoding: .utf8) else { return false }
            return FileManager.default.fileExists(atPath: path.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// 最後に使った時刻（印が無ければ `.git` の更新時刻）
    private func lastUsed(_ clone: URL) -> Date? {
        for url in [usedMarker(clone), clone.appendingPathComponent(".git")] {
            if let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date { return date }
        }
        return nil
    }

    // MARK: - 置き場所

    func cloneDirectory(of repo: RepositoryFullName) -> URL {
        setup.root.appendingPathComponent("repos/\(repo.owner)/\(repo.name)", isDirectory: true)
    }

    func jobDirectory(_ job: ULID) -> URL {
        setup.root.appendingPathComponent("jobs/\(job.rawValue)", isDirectory: true)
    }

    // MARK: - git

    /// clone が無ければ作り、あれば最新にする（既定のブランチが変わっていれば追う）
    private func update(_ clone: URL, of repo: RepositoryFullName) async throws(WorkspaceError) {
        if FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path) {
            try await git(["fetch", "--prune", "origin"], in: clone)
            try await git(["remote", "set-head", "origin", "--auto"], in: clone)
            return
        }
        let parent = clone.deletingLastPathComponent()
        try createDirectory(parent)
        // 途中で止まった clone の残りがあれば消してから作る
        try remove(clone)
        let url = "https://github.com/\(repo.owner)/\(repo.name).git"
        do {
            try await git(["clone", "--filter=blob:none", "--no-checkout", "--origin", "origin", url, clone.path], in: parent)
        } catch {
            try? remove(clone)
            throw error
        }
    }

    private func git(_ arguments: [String], in directory: URL) async throws(WorkspaceError) {
        let command = Command(
            executable: setup.git,
            arguments: arguments,
            environment: environment,
            workingDirectory: directory,
            timeout: setup.timeout
        )
        let result: CommandResult
        do {
            result = try await runner.run(command)
        } catch {
            throw .failed("git \(arguments.first ?? "") を起動できない（\(error.localizedDescription)）")
        }
        guard !result.succeeded else { return }
        throw Self.classify(result, command: arguments.first ?? "")
    }

    /// git に渡す環境変数。人の設定（`~/.gitconfig`・システムの設定）を読まず、決めた設定だけを渡す
    var environment: [String: String] {
        let config: [(String, String)] = [
            // リポジトリの hooks を動かさない（clone・checkout でも動くため）
            ("core.hooksPath", "/dev/null"),
            // シンボリックリンクは、指す先のパスを書いたファイルとして取り出す（Claude に写しの外を読ませない）
            ("core.symlinks", "false"),
            ("core.fsmonitor", "false"),
            ("credential.helper", setup.credentialHelper),
            ("protocol.file.allow", "never"),
            ("submodule.recurse", "false"),
            ("advice.detachedHead", "false")
        ]
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": setup.root.appendingPathComponent("home").path,
            "LANG": "C",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_COUNT": String(config.count)
        ]
        for (index, (key, value)) in config.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = key
            environment["GIT_CONFIG_VALUE_\(index)"] = value
        }
        return environment
    }

    /// git の失敗を、待ってやり直すもの（GitHub に届かない）・認証・そのほかに分ける
    static func classify(_ result: CommandResult, command: String) -> WorkspaceError {
        let message = String(bytes: result.standardError, encoding: .utf8) ?? ""
        let detail = "git \(command): \(message.split(separator: "\n").suffix(3).joined(separator: " "))"
        if result.timedOut { return .unavailable("git \(command) が時間内に終わらない") }
        let unauthorized = [
            "Authentication failed", "could not read Username", "Repository not found", "returned error: 401", "returned error: 403"
        ]
        if unauthorized.contains(where: message.contains) { return .unauthorized(detail) }
        let unavailable = [
            "Could not resolve host", "Failed to connect", "Connection timed out", "Operation timed out", "Connection reset",
            "returned error: 5", "remote end hung up", "early EOF", "SSL"
        ]
        if unavailable.contains(where: message.contains) { return .unavailable(detail) }
        return .failed(detail)
    }

    // MARK: - フォルダ

    private func createDirectory(_ directory: URL) throws(WorkspaceError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw .failed("\(directory.lastPathComponent) を作れない（\(error.localizedDescription)）")
        }
    }

    /// ワーカーが自分で作ったフォルダを消す。無ければ何もしない
    private func remove(_ directory: URL) throws(WorkspaceError) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw .failed("\(directory.lastPathComponent) を消せない（\(error.localizedDescription)）")
        }
    }
}

/// リポジトリごとに、処理を 1 つずつにする
actor RepositoryLocks {
    private var locked: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    nonisolated func withLock(_ key: String, _ body: () async throws(WorkspaceError) -> Void) async throws(WorkspaceError) {
        await acquire(key)
        do {
            try await body()
            await release(key)
        } catch {
            await release(key)
            throw error
        }
    }

    private func acquire(_ key: String) async {
        guard locked.contains(key) else {
            locked.insert(key)
            return
        }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    private func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            queue.removeFirst().resume()
            waiters[key] = queue.isEmpty ? nil : queue
        } else {
            locked.remove(key)
        }
    }
}
