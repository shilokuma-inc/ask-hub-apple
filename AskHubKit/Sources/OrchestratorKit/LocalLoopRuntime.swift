import Foundation
import os

/// この Mac でループの状態を調べ、`loopCommand` を起動する
public actor LocalLoopRuntime: LoopRuntime {
    /// 制御用 worktree の中の、ralph-loop の state ファイルの場所
    public static let stateFileRelativePath = ".claude/ralph-loop.local.md"

    /// 起動したプロセス。キーは `fullName` を小文字にしたもの。
    /// オーケストレーターを再起動すると忘れるが、その場合も state ファイルが残っていれば起動しない
    private var processes: [String: Process] = [:]

    /// SIGTERM を送ってから SIGKILL を送るまでの猶予
    private let killGracePeriod: Duration
    /// 終了後に出力の読み切りを待つ上限
    private let outputDrainTimeout: Duration

    public init(killGracePeriod: Duration = .seconds(10), outputDrainTimeout: Duration = .seconds(5)) {
        self.killGracePeriod = killGracePeriod
        self.outputDrainTimeout = outputDrainTimeout
    }

    public func status(of repository: RepositoryConfig) -> LoopStatus {
        let key = repository.fullName.lowercased()
        if processes[key]?.isRunning == false {
            processes[key] = nil
        }
        let stateFile = URL(fileURLWithPath: repository.controlWorktreePath, isDirectory: true)
            .appendingPathComponent(Self.stateFileRelativePath)
        return LoopStatus(
            stateFileExists: Self.fileExists(at: stateFile.path),
            processAlive: processes[key] != nil
        )
    }

    /// ファイルがあるか。`FileManager.fileExists` はアクセス権が無いときも `false` を返すため、
    /// 「無い」と「確かめられない」（`nil`）を区別する
    static func fileExists(at path: String) -> Bool? {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        } catch {
            return nil
        }
    }

    public func epicSnapshot(of repository: RepositoryConfig) -> EpicSnapshot {
        let control = URL(fileURLWithPath: repository.controlWorktreePath, isDirectory: true)
        func read(_ path: String) -> String? {
            try? String(contentsOf: control.appendingPathComponent(path), encoding: .utf8)
        }
        return EpicSnapshot(
            branch: Self.currentBranch(of: control),
            goal: read(".claude/ralph-goal.local.md"),
            state: read(".claude/ralph-state.local.md")
        )
    }

    /// worktree が checkout しているブランチ。`git` を起動せず、`.git`（worktree ではファイル）から `HEAD` をたどる
    static func currentBranch(of worktree: URL) -> String? {
        let dotGit = worktree.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = dotGit
        } else {
            // worktree の `.git` は `gitdir: <パス>` の 1 行
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8),
                  let path = pointer.split(whereSeparator: \.isNewline).first?.trimmingPrefix("gitdir: ") else {
                return nil
            }
            gitDirectory = URL(fileURLWithPath: String(path), relativeTo: worktree)
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) else {
            return nil
        }
        let reference = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        // detached HEAD（コミットのハッシュ）ではブランチが無い
        return reference.hasPrefix(prefix) ? String(reference.dropFirst(prefix.count)) : nil
    }

    /// `arguments` の先頭を実行ファイルとして、メインの checkout を作業ディレクトリに起動する。
    /// 先頭が絶対パスでなければ `PATH` から探す（launchd の `PATH` は最小限なので、絶対パスを推奨する）
    public func launch(_ arguments: [String], for repository: RepositoryConfig) throws {
        let process = try Self.makeProcess(arguments, in: repository)
        try process.run()
        processes[repository.fullName.lowercased()] = process
    }

    /// `arguments` を実行して終了を待ち、終了コードと出力（標準出力と標準エラー）を返す。
    ///
    /// `timeout` を過ぎたら SIGTERM を送り、`killGracePeriod` 待っても終わらなければ SIGKILL で止める。
    /// 出力は終了後に最長 `outputDrainTimeout` だけ読み切りを待つ（パイプを継承した子プロセスが残っても戻れるように）
    public func run(
        _ arguments: [String],
        input: String,
        for repository: RepositoryConfig,
        timeout: Duration
    ) async throws -> CommandResult {
        let process = try Self.makeProcess(arguments, in: repository)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let (exited, exit) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exit.yield(process.terminationStatus)
            exit.finish()
        }
        let collector = OutputCollector(reading: pipe.fileHandleForReading, limit: Self.maxOutputBytes)
        try process.run()

        // 入力はパイプの容量を超えうるので、読み手を待たせないよう別のタスクで書いて閉じる
        let writer = inputPipe.fileHandleForWriting
        // 子プロセスが標準入力を読まずに終了しても SIGPIPE でオーケストレーターごと落ちないようにする（EPIPE になる）
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let inputData = Data(input.utf8)
        Task.detached {
            try? writer.write(contentsOf: inputData)
            try? writer.close()
        }

        let pid = process.processIdentifier
        let killGracePeriod = killGracePeriod
        let timer = Task {
            try await Task.sleep(for: timeout)
            kill(pid, SIGTERM)
            try await Task.sleep(for: killGracePeriod)
            kill(pid, SIGKILL)
        }
        var status: Int32 = -1
        for await value in exited {
            status = value
        }
        timer.cancel()

        let output = await collector.finish(waitingAtMost: outputDrainTimeout)
        return CommandResult(status: status, output: output)
    }

    /// `run` で保持する出力の上限（末尾から）
    static let maxOutputBytes = 1_000_000

    /// 先頭が絶対パスでなければ `PATH` から探す。作業ディレクトリはメインの checkout
    private static func makeProcess(_ arguments: [String], in repository: RepositoryConfig) throws -> Process {
        guard let executable = arguments.first else {
            throw OrchestratorConfigError.emptyLoopCommand
        }
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = Array(arguments.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
        }
        process.currentDirectoryURL = URL(fileURLWithPath: repository.checkoutPath, isDirectory: true)
        return process
    }
}

/// コマンドの出力を届いた分から読み、末尾の `limit` バイトだけを保持する。
/// パイプが一杯になってコマンドが止まらないよう、終了を待つ前から読み続ける
private final class OutputCollector: Sendable {
    private let handle: FileHandle
    private let data = OSAllocatedUnfairLock(initialState: Data())
    private let closed: AsyncStream<Void>

    init(reading handle: FileHandle, limit: Int) {
        self.handle = handle
        let (closed, close) = AsyncStream<Void>.makeStream()
        self.closed = closed
        let data = data
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                close.finish()
                return
            }
            // URL は最後の行に出させるので、末尾があれば足りる
            data.withLock { data in
                data.append(chunk)
                if data.count > limit {
                    data.removeFirst(data.count - limit)
                }
            }
        }
    }

    /// 残りの出力を読み切って返す。子プロセスがパイプを持ち続けても、待つのは `timeout` まで
    func finish(waitingAtMost timeout: Duration) async -> String {
        let closed = closed
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in closed {}
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        handle.readabilityHandler = nil
        let bytes = data.withLock { $0 }
        // 末尾だけを残すと文字の途中で切れ、コマンドの出力に不正なバイトが混ざることもある。
        // 全体を失わないよう、壊れた部分を置き換えて読む（URL の行が読めればよい）
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: bytes, as: UTF8.self)
    }
}
