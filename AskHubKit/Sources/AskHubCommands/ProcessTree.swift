#if os(macOS)
import Darwin
import Foundation

/// コマンドとその子孫のプロセスを止める。
///
/// 子孫はコマンドを流した側と同じプロセスグループにいるのでグループごとには送れず、
/// 親が先に終わると launchd に付け替えられて辿れなくなるので、送る前に集める。
/// 待つ間に終わって PID が再利用されていたら送らないよう、起動時刻で同じプロセスかを確かめる
enum ProcessTree {
    struct Target: Hashable {
        var pid: pid_t
        var startedAt: Date
    }

    /// SIGINT → SIGTERM → SIGKILL の順に送る。どの段でも、残りが無くなれば待たずに終える
    static func stop(_ pid: pid_t, interruptGrace: Duration, terminateGrace: Duration) async {
        var targets = collect(from: pid)
        for (signal, grace) in [(SIGINT, interruptGrace), (SIGTERM, terminateGrace)] {
            // 前の段の間に起動した子孫も加える
            targets.formUnion(collect(from: pid))
            send(signal, to: targets)
            targets = await remaining(targets, waitingAtMost: grace)
            if targets.isEmpty { return }
        }
        send(SIGKILL, to: targets)
    }

    /// `pid` と、その子孫（浅いものから）
    static func collect(from pid: pid_t) -> Set<Target> {
        Set(([pid] + descendants(of: pid)).compactMap { target in startDate(of: target).map { Target(pid: target, startedAt: $0) } })
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [pid]
        while !queue.isEmpty, found.count < maximumDescendants {
            let parent = queue.removeFirst()
            let children = childProcesses(of: parent).filter { $0 != pid && !found.contains($0) }
            found += children
            queue += children
        }
        return found
    }

    /// 集める子孫の上限（念のため）
    private static let maximumDescendants = 1000

    private static func send(_ signal: Int32, to targets: Set<Target>) {
        for target in targets where startDate(of: target.pid) == target.startedAt {
            kill(target.pid, signal)
        }
    }

    /// 0.1 秒ごとに見て、`grace` の間に終わらなかったもの
    private static func remaining(_ targets: Set<Target>, waitingAtMost grace: Duration) async -> Set<Target> {
        let deadline = ContinuousClock.now + grace
        var alive = targets
        while true {
            alive = alive.filter { startDate(of: $0.pid) == $0.startedAt && !isZombie($0.pid) }
            if alive.isEmpty || ContinuousClock.now >= deadline { return alive }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// `pid` の子の PID（`proc_listchildpids`）。無ければ・読めなければ空
    private static func childProcesses(of pid: pid_t) -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        // 戻り値を件数として読む（バイト数を返す版でも、余りは 0 なので除ける）
        return buffer.prefix(min(Int(count), buffer.count)).filter { $0 > 0 }
    }

    /// プロセスの起動時刻。プロセスが無ければ nil
    static func startDate(of pid: pid_t) -> Date? {
        guard let info = info(of: pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// 終わったが、親がまだ終了を受け取っていない
    private static func isZombie(_ pid: pid_t) -> Bool {
        info(of: pid).map { $0.kp_proc.p_stat == SZOMB } ?? false
    }

    private static func info(of pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}
#endif
