import AskHubCommands
import AskHubProtocol
import Foundation

/// 呼ぶ側（Claude から頼まれたワーカー）が選ぶ、ビルドとテストの種類。コマンドの中身は `BuildSettings` から決まる
public enum BuildKind: String, Codable, Sendable, CaseIterable {
    /// ビルドだけ
    case build
    /// 子 PR 用の軽いテスト（`BuildSettings.pullRequestTests`）
    case pullRequestTests
    /// 最終 PR 用の全部のテスト（`BuildSettings.finalTests`）
    case finalTests

    public var action: BuildAction {
        switch self {
        case .build: .build
        case .pullRequestTests: .test(.pullRequest)
        case .finalTests: .test(.finalPullRequest)
        }
    }
}

/// 種類ごとの実行時間の上限
public struct BuildTimeouts: Equatable, Sendable {
    public var build: Duration
    public var pullRequestTests: Duration
    public var finalTests: Duration

    public init(
        build: Duration = .seconds(30 * 60),
        pullRequestTests: Duration = .seconds(45 * 60),
        finalTests: Duration = .seconds(90 * 60)
    ) {
        self.build = build
        self.pullRequestTests = pullRequestTests
        self.finalTests = finalTests
    }

    public func timeout(for kind: BuildKind) -> Duration {
        switch kind {
        case .build: build
        case .pullRequestTests: pullRequestTests
        case .finalTests: finalTests
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
/// Simulator の行き先は、枠 `slot` の Simulator を用意（無ければ作って起動）してから流す。同じ枠を同時に使わないのは呼ぶ側が守る
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
        let prepared: PreparedDestination
        switch destination {
        case .macOS:
            prepared = .macOS
        case .simulator(let simulator):
            do {
                prepared = .simulator(try await machine.pool.prepare(slot: slot, for: simulator))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                return BuildOutcome(failure: .environment, summary: error.message, report: BuildReport(log: error.log))
            }
        }
        let request = BuildRequest(
            settings: settings, action: kind.action, destination: prepared, sourceDirectory: sourceDirectory, epic: epic
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
