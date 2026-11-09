import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation

/// Claude に頼まれたビルドとテストを、`AskHubBuild` の `EpicBuilder` で流す（`BuildService` の本物）。
///
/// `timeout`（タスクの実行の残り）を過ぎたら、流しているビルドを取り消して止め（`xcodebuild` とその子孫のプロセスまで）、
/// `couldNotRun`（`timeout`）を返す。種類ごとの上限（`BuildTimeouts`）は `EpicBuilder` が守るので、短い方で止まる
public struct EpicBuildService: BuildService {
    /// 流すもの。本物は `EpicBuilder.run(_:)`。取り消されたら `CancellationError` を投げる
    public var build: @Sendable (BuildKind) async throws(CancellationError) -> BuildRun

    public init(builder: EpicBuilder) {
        build = { kind throws(CancellationError) in try await builder.run(kind) }
    }

    public init(build: @escaping @Sendable (BuildKind) async throws(CancellationError) -> BuildRun) {
        self.build = build
    }

    public func run(_ kind: TaskReport.BuildKind, timeout: Duration) async -> TaskBuildResult {
        guard let buildKind = BuildKind(rawValue: kind.rawValue) else {
            return .couldNotRun(AttemptFailure(failureClass: .unexpected, message: "ビルドの種類 \(kind.rawValue) を流せない"))
        }
        switch await race(buildKind, timeout: timeout) {
        case let .finished(run):
            return Self.result(of: run)
        case .timedOut:
            let message = "\(kind.rawValue) が、タスクの実行の残りの時間（\(timeout)）に終わらなかった"
            return .couldNotRun(AttemptFailure(failureClass: .timeout, message: message))
        case .cancelled:
            return .couldNotRun(AttemptFailure(failureClass: .macOffline, message: "ワーカーを止めたので、ビルドとテストを中断した"))
        }
    }

    private enum Race: Sendable {
        case finished(BuildRun)
        case timedOut
        case cancelled
    }

    /// ビルドと時間の上限を競わせる。上限が先に来たら、ビルドを取り消して、止まるのを待ってから返す
    private func race(_ kind: BuildKind, timeout: Duration) async -> Race {
        await withTaskGroup(of: Race.self) { [build] group in
            group.addTask {
                do {
                    return .finished(try await build(kind))
                } catch {
                    return .cancelled
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            // 取り消したビルドが、子孫のプロセスまで止めて戻るのを待つ（止める前に次の往復へ進まない）
            await group.waitForAll()
            return first
        }
    }

    /// 結果を Claude との往復の形にする。ビルドとテストの失敗は Claude に直させ、時間切れ・環境の不調は試行の失敗にする
    static func result(of run: BuildRun) -> TaskBuildResult {
        let text = Redaction.redact(run.text(), secrets: [])
        switch run.failure {
        case nil:
            return .passed(summary: text)
        case .build, .test:
            return .failed(summary: text)
        case .timeout, .environment, .unknown:
            guard var failure = run.attemptFailure else {
                return .couldNotRun(AttemptFailure(failureClass: .unexpected, message: "ビルドとテストを流せなかった"))
            }
            failure.message = Redaction.redact(failure.message, secrets: [])
            failure.logExcerpt = failure.logExcerpt.flatMap { Redaction.excerpt(of: $0, secrets: []) }
            return .couldNotRun(failure)
        }
    }
}

/// この Mac のビルドの枠（`EpicBuilder` の Simulator の枠の番号）。同じ枠を同時に使わないよう、ジョブの間だけ貸す。
///
/// 同時に動かすビルドの数は `JobSlots` が Mac の上限（`capacity.build`）で抑えるので、枠の数は上限と同じにする
public actor BuildSlots {
    /// 枠を待っているジョブ。`slot` が nil なら、どの枠でもよい
    private struct Waiter {
        var slot: Int?
        var continuation: CheckedContinuation<Int, Never>
    }

    nonisolated public let count: Int
    private var used: Set<Int> = []
    private var waiters: [Waiter] = []

    public init(count: Int) {
        self.count = max(count, 1)
    }

    /// 空いている枠のうち、番号の小さいものを借りる。空きが無ければ、返されるまで待つ
    public func acquire() async -> Int {
        if let free = (0..<count).first(where: { !used.contains($0) }) {
            used.insert(free)
            return free
        }
        return await withCheckedContinuation { waiters.append(Waiter(slot: nil, continuation: $0)) }
    }

    /// 番号 `slot` の枠を借りる（枠の Simulator を片付けるときなど）。使われていれば、返されるまで待つ
    public func acquire(slot: Int) async {
        guard used.contains(slot) else {
            used.insert(slot)
            return
        }
        _ = await withCheckedContinuation { waiters.append(Waiter(slot: slot, continuation: $0)) }
    }

    /// 枠が空くのを待っているジョブの数（テストで使う）
    var waiting: Int { waiters.count }

    /// 枠を返す。その枠を待っているジョブ（どの枠でもよいものを含む）があれば、待った順に渡す
    public func release(_ slot: Int) {
        if let index = waiters.firstIndex(where: { $0.slot == nil || $0.slot == slot }) {
            waiters.remove(at: index).continuation.resume(returning: slot)
        } else {
            used.remove(slot)
        }
    }

    /// 枠を借りて `body` を流し、終わったら返す
    nonisolated public func withSlot<Value: Sendable>(_ body: (Int) async -> Value) async -> Value {
        let slot = await acquire()
        let value = await body(slot)
        await release(slot)
        return value
    }
}
