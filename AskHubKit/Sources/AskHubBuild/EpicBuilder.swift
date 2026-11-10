import AskHubCommands
import AskHubProtocol
import Foundation

/// 種類ごとの実行時間の上限
public struct BuildTimeouts: Equatable, Sendable {
    public var build: Duration
    public var testLight: Duration
    public var testFull: Duration

    public init(
        build: Duration = .seconds(30 * 60),
        testLight: Duration = .seconds(45 * 60),
        testFull: Duration = .seconds(90 * 60)
    ) {
        self.build = build
        self.testLight = testLight
        self.testFull = testFull
    }

    public func timeout(for kind: BuildKind) -> Duration {
        switch kind {
        case .build: build
        case .testLight: testLight
        case .testFull: testFull
        }
    }
}

/// ワーカーの Mac のビルドの道具一式（枠の Simulator と `xcodebuild`）。Mac ごとに 1 つ作る
public struct BuildMachine: Sendable {
    public var pool: SimulatorPool
    public var runner: XcodeBuildRunner
    public var timeouts: BuildTimeouts

    public init(tools: BuildTools, directories: BuildDirectories, runner: any CommandRunning, timeouts: BuildTimeouts = BuildTimeouts()) {
        pool = SimulatorPool(tools: tools, runner: runner)
        self.runner = XcodeBuildRunner(tools: tools, directories: directories, runner: runner)
        self.timeouts = timeouts
    }
}

/// 1 つの epic の写しで、種類を選んでビルドとテストを流す入口。
///
/// 設定の行き先を並べた順に流し、最初に失敗した行き先で止める（Claude に早く直させるため）。
/// Simulator の行き先は、枠 `slot` の Simulator を用意（無ければ作って起動）してから流す。アプリかテストの実行役を起動できなかったら
/// （`BuildOutcome.launchFailed`）、Simulator を消去して起動し直し、1 回だけ流し直す。同じ枠を同時に使わないのは呼ぶ側が守る
public struct EpicBuilder: Sendable {
    public var machine: BuildMachine
    public var settings: BuildSettings
    public var epic: ULID
    /// ビルドする写し（epic の worktree）
    public var sourceDirectory: URL
    public var slot: Int

    public init(machine: BuildMachine, settings: BuildSettings, epic: ULID, sourceDirectory: URL, slot: Int) {
        self.machine = machine
        self.settings = settings
        self.epic = epic
        self.sourceDirectory = sourceDirectory
        self.slot = slot
    }

    /// 流して結果を返す。失敗も結果として返し、投げるのは取り消されたときだけ
    public func run(_ kind: BuildKind) async throws(CancellationError) -> BuildRun {
        var results: [DestinationOutcome] = []
        for destination in settings.destinations {
            let outcome = try await run(kind, on: destination)
            results.append(DestinationOutcome(destination: destination, outcome: outcome))
            if !outcome.succeeded { break }
        }
        return BuildRun(kind: kind, results: results)
    }

    private func run(_ kind: BuildKind, on destination: BuildDestination) async throws(CancellationError) -> BuildOutcome {
        guard case .simulator(let target) = destination else {
            return try await xcodebuild(kind, on: .macOS)
        }
        let simulator: Simulator
        do {
            simulator = try await machine.pool.prepare(slot: slot, for: target)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return BuildOutcome(failure: .environment, summary: error.message, report: BuildReport(log: error.log))
        }
        let outcome = try await xcodebuild(kind, on: .simulator(simulator))
        guard outcome.launchFailed else { return outcome }
        return try await rerun(kind, on: target, resetting: simulator, after: outcome)
    }

    /// Simulator でアプリかテストの実行役を起動できなかったときに、枠の Simulator を止めて中身を消去し、起動し直してから 1 回だけ流し直す。
    ///
    /// Simulator の中の状態が壊れると、入れたアプリを起動できなくなる（2026-11-10 08:46Z に Mac mini で起き、
    /// 人が止めて起動し直すと通った）。流し直しても駄目なら、その結果を返す（環境の不調として人に渡る）
    private func rerun(
        _ kind: BuildKind,
        on target: SimulatorDestination,
        resetting simulator: Simulator,
        after first: BuildOutcome
    ) async throws(CancellationError) -> BuildOutcome {
        let reset: Simulator
        do {
            try await machine.pool.erase(simulator)
            reset = try await machine.pool.prepare(slot: slot, for: target)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            var outcome = first
            outcome.summary += "。Simulator を消去して起動し直せなかった（\(error.message)）"
            return outcome
        }
        var outcome = try await xcodebuild(kind, on: .simulator(reset))
        outcome.summary += outcome.launchFailed
            ? "。Simulator を消去して起動し直し、流し直しても、アプリかテストの実行役を起動できなかった"
            : "。1 回目は Simulator でアプリかテストの実行役を起動できず、Simulator を消去して起動し直してから流し直した"
        return outcome
    }

    private func xcodebuild(_ kind: BuildKind, on destination: PreparedDestination) async throws(CancellationError) -> BuildOutcome {
        let request = BuildRequest(
            settings: settings, kind: kind, destination: destination, sourceDirectory: sourceDirectory, epic: epic
        )
        return try await machine.runner.run(request, timeout: machine.timeouts.timeout(for: kind))
    }
}

/// 行き先ごとの結果
public struct DestinationOutcome: Equatable, Sendable {
    public var destination: BuildDestination
    public var outcome: BuildOutcome

    public init(destination: BuildDestination, outcome: BuildOutcome) {
        self.destination = destination
        self.outcome = outcome
    }
}

/// `EpicBuilder.run(_:)` の結果
public struct BuildRun: Equatable, Sendable {
    public var kind: BuildKind
    /// 流した行き先の結果（失敗した行き先までで、その後の行き先は流していない）
    public var results: [DestinationOutcome]

    public init(kind: BuildKind, results: [DestinationOutcome]) {
        self.kind = kind
        self.results = results
    }

    /// 最初に失敗した行き先の区分。すべて通ったら nil
    public var failure: BuildFailureKind? {
        results.lazy.compactMap(\.outcome.failure).first
    }

    public var succeeded: Bool { failure == nil }

    /// 行き先ごとの短い説明（`iPhone 17 Pro（iOS）: テストが通った（全 12 件）` の形を改行でつなぐ）
    public var summary: String {
        results.map { "\($0.destination.label): \($0.outcome.summary)" }.joined(separator: "\n")
    }

    /// Claude に渡す文。行き先ごとの説明と、失敗した行き先の要約を `limit` 文字までにする
    public func text(limit: Int = BuildReport.defaultLimit) -> String {
        let details = results.filter { !$0.outcome.succeeded }.map { result in
            "\(result.destination.label) の結果:\n" + result.outcome.report.text(limit: limit)
        }
        return BuildReport.truncate(([summary] + details).joined(separator: "\n\n"), limit: limit)
    }

    /// 試行の失敗として書く形。すべて通ったら nil
    public var attemptFailure: AttemptFailure? {
        guard let failed = results.first(where: { !$0.outcome.succeeded }), let failure = failed.outcome.failure else { return nil }
        let excerpt = failed.outcome.report.text(limit: Redaction.maximumExcerpt)
        return AttemptFailure(
            failureClass: failure.failureClass,
            message: "\(failed.destination.label): \(failed.outcome.summary)",
            logExcerpt: excerpt.isEmpty ? nil : excerpt
        )
    }
}

extension BuildDestination {
    /// 人と Claude に見せる名前（`iPhone 17 Pro（iOS 26.5）`・`macOS`）
    public var label: String {
        switch self {
        case .macOS: "macOS"
        case .simulator(let destination):
            "\(destination.deviceType)（\(destination.platform.rawValue)\(destination.osVersion.map { " \($0)" } ?? "")）"
        }
    }
}
