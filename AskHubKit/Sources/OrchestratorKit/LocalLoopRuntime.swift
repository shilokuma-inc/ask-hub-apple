import Foundation
import os

/// この Mac でループの状態を調べ、`loopCommand` を起動する
public actor LocalLoopRuntime: LoopRuntime {
    /// 制御用 worktree の中の、ralph-loop の state ファイルの場所
    public static let stateFileRelativePath = ".claude/ralph-loop.local.md"
    /// 起動スクリプト（askhub-start-loop）が書く、ループのプロセスの PID。
    /// state ファイルが残ったままプロセスが死んだ（落ちた・止められた）ことを見分けるのに使う
    public static let pidFileRelativePath = ".claude/askhub-loop.pid"
    /// 起動スクリプトが、準備の結果 goal にタスクが無かった Discussion の番号を書く
    public static let noTasksFileRelativePath = ".claude/askhub-no-tasks.local.txt"

    /// 起動したプロセス。キーは `fullName` を小文字にしたもの。
    /// オーケストレーターを再起動すると忘れるが、その場合も state ファイルが残っていれば起動しない
    private var processes: [String: Process] = [:]

    /// SIGTERM を送ってから SIGKILL を送るまでの猶予
    private let killGracePeriod: Duration
    /// 終了後に出力の読み切りを待つ上限
    private let outputDrainTimeout: Duration

    /// 起動するコマンドに追加で渡す環境変数（継承した環境変数は残す）
    private let environment: [String: String]
    /// 起動スクリプトがループのログを置く場所。`<リポジトリ名>-latest.log` が最新のログを指す
    private let loopLogDirectory: URL

    /// - Parameter loopLogDirectory: 省略すると、起動スクリプトと同じく `ASKHUB_LOG_DIR` か `~/Library/Logs/askhub/loops`
    public init(
        killGracePeriod: Duration = .seconds(10),
        outputDrainTimeout: Duration = .seconds(5),
        environment: [String: String] = [:],
        loopLogDirectory: URL? = nil
    ) {
        self.killGracePeriod = killGracePeriod
        self.outputDrainTimeout = outputDrainTimeout
        self.environment = environment
        let configured = environment["ASKHUB_LOG_DIR"] ?? ProcessInfo.processInfo.environment["ASKHUB_LOG_DIR"]
        self.loopLogDirectory = loopLogDirectory
            ?? configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/askhub/loops", isDirectory: true)
    }

    public func hungLoop(of repository: RepositoryConfig, timeout: Duration, now: Date) -> HungLoop? {
        let control = URL(fileURLWithPath: repository.controlWorktreePath, isDirectory: true)
        let pidFile = control.appendingPathComponent(Self.pidFileRelativePath)
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              let recordedAt = Self.modificationDate(of: pidFile),
              let processStartedAt = Self.recordedLoopStartDate(pid: pid, recordedAt: recordedAt),
              let started = Self.modificationDate(of: control.appendingPathComponent(Self.stateFileRelativePath)),
              now.timeIntervalSince(started) > TimeInterval(timeout.components.seconds) else {
            return nil
        }
        return HungLoop(pid: pid, iterationStartedAt: started, processStartedAt: processStartedAt)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// `pid` のプロセスが生きていて、PID ファイルに記録したループそのものか。
    /// 起動スクリプトは自分の PID を書いてから `claude` に exec するので、ループのプロセスは PID ファイルより前に起動している。
    /// ループが終わった後に PID が別のプロセスに再利用されていれば、そのプロセスは PID ファイルより後に起動している（止めてはいけない）
    /// そうならプロセスの起動時刻、違えば `nil`
    static func recordedLoopStartDate(pid: pid_t, recordedAt: Date) -> Date? {
        guard kill(pid, 0) == 0, let startedAt = processStartDate(pid: pid),
              // ファイルの時刻と起動時刻の精度の差を見込む
              startedAt <= recordedAt.addingTimeInterval(1) else {
            return nil
        }
        return startedAt
    }

    /// プロセスの起動時刻（`sysctl` の `kinfo_proc`）
    static func processStartDate(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    public func clearNoTasksMarker(of repository: RepositoryConfig) {
        let control = URL(fileURLWithPath: repository.controlWorktreePath, isDirectory: true)
        try? FileManager.default.removeItem(at: control.appendingPathComponent(Self.noTasksFileRelativePath))
    }

    public func terminate(_ loop: HungLoop) async {
        guard Self.isSameProcess(loop), kill(loop.pid, SIGTERM) == 0 else {
            return
        }
        try? await Task.sleep(for: killGracePeriod)
        // 猶予の間に終わって PID が再利用されていたら、送らない
        if Self.isSameProcess(loop) {
            kill(loop.pid, SIGKILL)
        }
    }

    /// `loop.pid` が、見つけたときと同じプロセス（起動時刻が同じ）か
    static func isSameProcess(_ loop: HungLoop) -> Bool {
        guard let expected = loop.processStartedAt, let current = processStartDate(pid: loop.pid) else {
            return false
        }
        return current == expected
    }

    /// 最新のログの末尾（このバイト数）だけを読む
    static let logTailBytes = 8 * 1024

    public func usageLimitReset(of repository: RepositoryConfig) -> Date? {
        let latest = loopLogDirectory.appendingPathComponent("\(repository.name)-latest.log").resolvingSymlinksInPath()
        guard let handle = try? FileHandle(forReadingFrom: latest) else {
            return nil
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > UInt64(Self.logTailBytes) ? size - UInt64(Self.logTailBytes) : 0)) != nil,
              let data = try? handle.readToEnd(),
              let modified = (try? FileManager.default.attributesOfItem(atPath: latest.path))?[.modificationDate] as? Date else {
            return nil
        }
        // 末尾だけを読むと文字の途中で切れることがあるので、壊れた部分は置き換えて読む
        // swiftlint:disable:next optional_data_string_conversion
        return UsageLimit.resetDate(in: String(decoding: data, as: UTF8.self), loggedAt: modified)
    }

    public func lastActivity(of repository: RepositoryConfig) -> Date? {
        let control = URL(fileURLWithPath: repository.controlWorktreePath, isDirectory: true)
        let files = [Self.stateFileRelativePath, ".claude/ralph-state.local.md", ".claude/ralph-goal.local.md"]
            .map { control.appendingPathComponent($0) }
            + [loopLogDirectory.appendingPathComponent("\(repository.name)-latest.log").resolvingSymlinksInPath()]
        return files.compactMap(Self.modificationDate(of:)).max()
    }

    public func status(of repository: RepositoryConfig) -> LoopStatus {
        let key = repository.fullName.lowercased()
        if processes[key]?.isRunning == false {
            processes[key] = nil
        }
        let control = URL(fileURLWithPath: repository.controlWorktreePath, isDirectory: true)
        var stateFileExists = Self.fileExists(at: control.appendingPathComponent(Self.stateFileRelativePath).path)
        var stalled = false
        // state ファイルが残っていても、記録した PID のプロセスが居なければループは止まっている（落ちた・止められた）。
        // 起動スクリプトがそれを見て state を片付けてから再開するので、ここでは「無い」とみなす
        if stateFileExists == true, processes[key] == nil,
           Self.recordedProcessIsGone(pidFile: control.appendingPathComponent(Self.pidFileRelativePath)) {
            stateFileExists = false
            stalled = true
        }
        return LoopStatus(stateFileExists: stateFileExists, processAlive: processes[key] != nil, stalled: stalled)
    }

    /// PID ファイルに記録したプロセスが居なくなっているか。PID ファイルが無い・読めないときは判断できないので `false`
    static func recordedProcessIsGone(pidFile: URL) -> Bool {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            return false
        }
        return kill(pid, 0) == -1 && errno == ESRCH
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
        func number(_ path: String) -> Int? {
            read(path)
                .flatMap { $0.split(whereSeparator: \.isNewline).first }
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        return EpicSnapshot(
            branch: Self.currentBranch(of: control),
            goal: read(".claude/ralph-goal.local.md"),
            state: read(".claude/ralph-state.local.md"),
            discussion: number(".claude/askhub-bootstrap.local.txt"),
            loopPrepared: read(".claude/askhub-promise.local.txt")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            noTasksDiscussion: number(Self.noTasksFileRelativePath)
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
        let process = try Self.makeProcess(arguments, in: repository, environment: environment)
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
        let process = try Self.makeProcess(arguments, in: repository, environment: environment)
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
    private static func makeProcess(
        _ arguments: [String],
        in repository: RepositoryConfig,
        environment: [String: String]
    ) throws -> Process {
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
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
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
