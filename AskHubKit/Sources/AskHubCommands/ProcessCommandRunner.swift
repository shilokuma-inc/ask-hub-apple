#if os(macOS)
import Darwin
import Foundation
import os

/// `Process` でコマンドを流す。標準入力は `/dev/null`、環境変数は `Command.environment` だけを渡す
public struct ProcessCommandRunner: CommandRunning {
    /// 標準出力・標準エラーそれぞれで保持する上限（末尾から）
    public var outputLimit: Int
    /// 終わった後に出力を読み切るまで待つ上限（パイプを継承した子プロセスが残っても戻れるように）
    public var outputDrainTimeout: Duration

    public init(outputLimit: Int = 4_000_000, outputDrainTimeout: Duration = .seconds(5)) {
        self.outputLimit = outputLimit
        self.outputDrainTimeout = outputDrainTimeout
    }

    /// 呼んだタスクが取り消されたら、コマンドとその子孫を止めてから `CancellationError` を投げる
    public func run(_ command: Command) async throws -> CommandResult {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.workingDirectory
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let (exited, exit) = AsyncStream<(status: Int32, signaled: Bool)>.makeStream()
        process.terminationHandler = { process in
            exit.yield((process.terminationStatus, process.terminationReason == .uncaughtSignal))
            exit.finish()
        }
        let standardOutput = OutputBuffer(reading: output.fileHandleForReading, limit: outputLimit)
        let standardError = OutputBuffer(reading: error.fileHandleForReading, limit: outputLimit)
        try process.run()

        let pid = process.processIdentifier
        // 起動した直後に起動時刻を読む。読めなければ、もう終わっている
        let root = ProcessTree.startDate(of: pid).map { ProcessTree.Target(pid: pid, startedAt: $0) }
        let stop = { @Sendable in
            if let root {
                await ProcessTree.stop(root, interruptGrace: command.interruptGrace, terminateGrace: command.terminateGrace)
            }
        }
        // 上限を過ぎたか。過ぎた後は、コマンドが先に終わっても、残った子孫を止めるまで続ける
        let expired = OSAllocatedUnfairLock(initialState: false)
        let timer = Task {
            try await Task.sleep(for: command.timeout)
            expired.withLock { $0 = true }
            await stop()
        }
        var termination = (status: Int32(-1), signaled: false)
        // 取り消されると、終了を待たずに抜ける
        for await value in exited {
            termination = value
        }
        if Task.isCancelled {
            timer.cancel()
            // 取り消されたタスクの中では待ち（猶予）がすぐ終わってしまうので、取り消されていないタスクで止める
            await Task.detached(operation: stop).value
            throw CancellationError()
        }
        let timedOut = expired.withLock { $0 }
        if !timedOut { timer.cancel() }

        return CommandResult(
            status: termination.status,
            terminatedBySignal: termination.signaled,
            standardOutput: await standardOutput.finish(waitingAtMost: outputDrainTimeout),
            standardError: await standardError.finish(waitingAtMost: outputDrainTimeout),
            timedOut: timedOut
        )
    }
}

/// パイプの出力を届いた分から読み、末尾の `limit` バイトだけを保持する。
/// パイプが一杯になってコマンドが止まらないよう、終了を待つ前から読み続ける
final class OutputBuffer: Sendable {
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
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                close.finish()
                return
            }
            data.withLock { data in
                data.append(chunk)
                if data.count > limit { data.removeFirst(data.count - limit) }
            }
        }
    }

    /// 残りを読み切って返す。子プロセスがパイプを持ち続けても、待つのは `timeout` まで
    func finish(waitingAtMost timeout: Duration) async -> Data {
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
        return data.withLock { $0 }
    }
}
#endif
