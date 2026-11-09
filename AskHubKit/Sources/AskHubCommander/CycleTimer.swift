import Foundation

/// 1 周の手順ごとにかかった時間。人の意図の受け付けが遅れる周を見つけられるよう、長くかかった周だけログに出す
struct CycleTimer {
    /// これより長くかかった周をログに出す
    static let slowCycle: Duration = .seconds(20)

    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var last: ContinuousClock.Instant
    private(set) var steps: [(name: String, duration: Duration)] = []

    init() {
        start = clock.now
        last = start
    }

    /// 前の区切りから今までを、`name` の手順にかかった時間として残す
    mutating func lap(_ name: String) {
        let now = clock.now
        steps.append((name, now - last))
        last = now
    }

    var total: Duration { last - start }

    /// 長くかかった周の知らせ。短ければ nil
    var report: String? {
        Self.report(steps: steps, total: total)
    }

    static func report(steps: [(name: String, duration: Duration)], total: Duration) -> String? {
        guard total >= slowCycle else { return nil }
        let parts = steps.map { "\($0.name) \(seconds($0.duration)) 秒" }.joined(separator: "・")
        return "1 周に \(seconds(total)) 秒かかった（\(parts)）"
    }

    /// 小数 1 桁の秒
    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f", value)
    }
}
