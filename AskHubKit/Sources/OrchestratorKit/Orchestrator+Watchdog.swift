import Foundation

/// 固まったとみなしたループのプロセス
public struct HungLoop: Sendable, Equatable {
    public let pid: Int32
    /// 今の周回の開始（state ファイルの更新）の時刻
    public let iterationStartedAt: Date
    /// 見つけたときのプロセスの起動時刻。シグナルを送る直前に照合し、PID が再利用された別のプロセスを止めない
    public let processStartedAt: Date?

    public init(pid: Int32, iterationStartedAt: Date, processStartedAt: Date? = nil) {
        self.pid = pid
        self.iterationStartedAt = iterationStartedAt
        self.processStartedAt = processStartedAt
    }
}

// 1 周が長すぎるループを固まったとみなして止める（ralph-loop の Stop hook は周回ごとに state ファイルを書き直す）
extension Orchestrator {
    func terminateHungLoops() async {
        let current = now()
        for repository in config.repositories {
            guard let hung = await runtime.hungLoop(of: repository, timeout: config.iterationTimeout, now: current) else {
                continue
            }
            let minutes = Int(current.timeIntervalSince(hung.iterationStartedAt) / 60)
            log("\(repository.fullName) のループ（PID \(hung.pid)）の今の周回が \(minutes) 分進んでいないので、固まったとみなして止めます")
            await runtime.terminate(hung)
        }
    }
}
