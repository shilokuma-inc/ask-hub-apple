import AskHubKit
import Foundation

/// xcb のイベント（`XcbEvent`）を古い順に受け取り、ジョブと Mac の状態を組み立てる。
///
/// - ジョブ: 今の Mac・何回目の試行か・別の Mac への移動（移動元 → 移動先・理由・時刻）・結果
/// - Mac: 状態（使える・切断・外している）・使えない理由の分類・実行中の本数（ループのスロット以外のビルドも含める）
///
/// ループのスロットのビルドだけを、`resolveSlot` で決めたリポジトリとスロットに結び付ける（Discussion #366 の Q6）。
/// 終わったビルドは、スロットごとの直近の 1 件と、移動のあったものを直近 24 時間分だけ保つ（Q4）。
/// ジョブの `path`（ローカルパス）は外に出さない
public struct XcbBuildTracker: Sendable {
    /// 移動のあったビルドを残す時間
    public static let movedRetention: TimeInterval = 24 * 60 * 60
    /// 移動のあったビルドを残す件数の上限（リポジトリごと）
    public static let movedLimit = 20
    /// 終わりのイベントが無いまま、この時間より前に始まったジョブは実行中から外す（xcb が強制終了されたときなど）
    public static let staleJobAge: TimeInterval = 6 * 60 * 60

    /// ジョブの作業ツリーのパスから、ループのリポジトリ（`owner/name`）とスロット（`a` / `b`）を決める。スロット以外は `nil`
    public typealias SlotResolver = @Sendable (_ path: String) -> (repository: String, slot: String)?

    private struct Job: Sendable {
        var owner: (repository: String, slot: String)?
        var action: String
        var platform: String?
        var startedAt: Date?
        var host: String?
        var attempt: Int?
        var moves: [LoopStatusBuildMove] = []
    }

    private struct Host: Sendable {
        var isDown = false
        var reason: BuildHost.Reason?
        var isDrained = false
    }

    private let resolveSlot: SlotResolver
    /// 実行中のジョブ（キーは xcb のジョブの `id`）
    private var jobs: [String: Job] = [:]
    /// 終わったビルド（リポジトリ → スロット → 直近の 1 件）
    private var latest: [String: [String: LoopStatusBuild]] = [:]
    /// 終わった、移動のあったビルド（リポジトリごと。古い順）
    private var moved: [String: [LoopStatusBuild]] = [:]
    /// Mac（イベントに出てきた順）
    private var hostOrder: [String] = []
    private var hostStates: [String: Host] = [:]

    public init(resolveSlot: @escaping SlotResolver) {
        self.resolveSlot = resolveSlot
    }

    // MARK: - イベント

    /// イベントを古い順に取り込む
    public mutating func apply(_ events: [XcbEvent]) {
        for event in events {
            apply(event)
        }
    }

    public mutating func apply(_ event: XcbEvent) {
        switch event.kind {
        case let .jobStarted(started):
            jobs[started.id] = Job(
                owner: resolveSlot(started.path), action: started.action, platform: started.platform, startedAt: event.time
            )
        case let .jobAttempt(id, host, attempt):
            noteHost(host)
            guard var job = jobs[id] else {
                return
            }
            job.host = host
            job.attempt = attempt ?? job.attempt.map { $0 + 1 } ?? 1
            // 移動先が決まっていない最後の移動の行き先は、この Mac
            if let last = job.moves.indices.last, job.moves[last].to == nil {
                job.moves[last].to = host
            }
            jobs[id] = job
        case let .jobMoved(id, from, reason):
            noteHost(from)
            jobs[id]?.host = nil
            jobs[id]?.moves.append(LoopStatusBuildMove(
                from: from, reason: reason.flatMap(LoopStatusBuildMove.Reason.init(rawValue:)) ?? .unknown, movedAt: event.time
            ))
        case .jobWaiting:
            break
        case let .jobFinished(finished):
            finish(finished, at: event.time)
        case let .hostState(host, state, reason):
            noteHost(host)
            hostStates[host]?.isDown = state == "down"
            hostStates[host]?.reason = state == "down" ? Self.hostReason(reason) : nil
        case let .hostDrained(host):
            noteHost(host)
            hostStates[host]?.isDrained = true
        case let .hostUndrained(host):
            noteHost(host)
            hostStates[host]?.isDrained = false
        }
    }

    private mutating func finish(_ finished: XcbEvent.Finished, at time: Date) {
        let job = jobs.removeValue(forKey: finished.id)
        // 始まりのイベントを読んでいない（読み始める前に始まった）ジョブだけ、終わりのイベントの path で決める
        let resolved = job.map(\.owner) ?? finished.path.flatMap(resolveSlot)
        guard let owner = resolved,
              let action = finished.action ?? job?.action
        else {
            return
        }
        let build = LoopStatusBuild(
            slot: owner.slot,
            action: action,
            platform: finished.platform ?? job?.platform,
            host: finished.host,
            attempt: finished.attempts ?? job?.attempt,
            moves: job?.moves ?? [],
            exitCode: finished.exitCode,
            seconds: finished.seconds,
            startedAt: job?.startedAt,
            finishedAt: time
        )
        latest[owner.repository, default: [:]][owner.slot] = build
        // 移動を読めていなくても、xcb が数えた移動の回数があれば移動のあったビルドとして残す
        if !build.moves.isEmpty || (finished.moves ?? 0) > 0 {
            moved[owner.repository, default: []].append(build)
        }
        if let host = finished.host {
            noteHost(host)
        }
    }

    private mutating func noteHost(_ name: String) {
        guard hostStates[name] == nil else {
            return
        }
        hostOrder.append(name)
        hostStates[name] = Host()
    }

    /// xcb の理由の文はローカルパスを含むことがあるので、分類だけにする
    static func hostReason(_ text: String?) -> BuildHost.Reason {
        guard let text else {
            return .unknown
        }
        if text.contains("Xcode") {
            return .xcodeNotReady
        }
        if text.contains("切断") {
            return .disconnected
        }
        if text.contains("接続できない") {
            return .unreachable
        }
        return .unknown
    }

    // MARK: - 結果

    /// 古くなったものを捨てる（24 時間より前の移動・終わりのイベントが来ないジョブ）
    public mutating func prune(now: Date) {
        jobs = jobs.filter { _, job in
            job.startedAt.map { now.timeIntervalSince($0) < Self.staleJobAge } ?? true
        }
        moved = moved.mapValues { builds in
            let recent = builds.filter { build in
                (build.finishedAt ?? build.startedAt).map { now.timeIntervalSince($0) < Self.movedRetention } ?? false
            }
            return Array(recent.suffix(Self.movedLimit))
        }
        .filter { !$0.value.isEmpty }
    }

    /// リポジトリのループのスロットのビルド（`loop-status` の `builds`）。`prune(now:)` の後に呼ぶ
    public func builds(for repository: String) -> LoopStatusBuilds {
        let running = jobs.values
            .filter { $0.owner?.repository == repository }
            .compactMap { job -> LoopStatusBuild? in
                job.owner.map { owner in
                    LoopStatusBuild(
                        slot: owner.slot,
                        action: job.action,
                        platform: job.platform,
                        host: job.host,
                        attempt: job.attempt,
                        moves: job.moves,
                        startedAt: job.startedAt
                    )
                }
            }
            .sorted { ($0.slot, $0.startedAt ?? .distantPast) < ($1.slot, $1.startedAt ?? .distantPast) }
        return LoopStatusBuilds(
            running: running,
            latest: (latest[repository] ?? [:]).sorted { $0.key < $1.key }.map(\.value),
            moved: (moved[repository] ?? []).reversed()
        )
    }

    /// 実行中の、ループのスロットのビルド（`build-hosts` の `jobs`）。Mac が決まっていない（移動中・待ち）ものは除く
    public var hostJobs: [BuildHostJob] {
        jobs.values
            .compactMap { job -> BuildHostJob? in
                guard let owner = job.owner, let host = job.host else {
                    return nil
                }
                return BuildHostJob(
                    host: host,
                    repository: owner.repository,
                    slot: owner.slot,
                    action: job.action,
                    platform: job.platform,
                    attempt: job.attempt,
                    startedAt: job.startedAt
                )
            }
            .sorted { ($0.host, $0.repository, $0.slot) < ($1.host, $1.repository, $1.slot) }
    }

    /// イベントに出てきた Mac の状態（`build-hosts` の `hosts`）。load・空きメモリ・枠は `xcb status --json` で足す。
    /// `local`（xcb を動かしている Mac）は、使えるときは待機（リモートが無いときだけ使う）とする
    public var hosts: [BuildHost] {
        hostOrder.compactMap { name in
            hostStates[name].map { host in
                let state: BuildHost.State = if host.isDrained {
                    .drained
                } else if host.isDown {
                    .down
                } else {
                    name == "local" ? .standby : .ok
                }
                return BuildHost(
                    name: name,
                    state: state,
                    reason: host.isDown ? host.reason : nil,
                    running: jobs.values.reduce(0) { $0 + ($1.host == name ? 1 : 0) }
                )
            }
        }
    }
}
