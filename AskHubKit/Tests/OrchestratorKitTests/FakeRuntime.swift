import AskHubKit
import Foundation
@testable import OrchestratorKit
import os

struct FakeRuntimeState {
    var launched: [[String]] = []
    var launchEnvironments: [[String: String]] = [] // 起動ごとに追加で渡した環境変数（`launched` と同じ順）
    var status = LoopStatus.idle
    var launchFails = false
    var epic = EpicSnapshot(branch: "epic/mvp", goal: nil, state: nil)
    var usageLimitReset: Date?
    var hungLoop: HungLoop?
    var terminated: [HungLoop] = []
    var clearedNoTasksMarkers = 0
    var lastActivity: Date?
    /// `run` が順に返す結果。尽きたら最後のものを返し続ける
    var runResults: [CommandResult] = [CommandResult(status: 0, output: "")]
    var ran: [[String]] = []
    var ranFor: [String] = [] // run を実行したリポジトリ（`ran` と同じ順）
    var inputs: [String] = []
    var runEnvironments: [[String: String]] = [] // run ごとに追加で渡した環境変数（`ran` と同じ順）
    /// run の時点で、引数に渡されたディレクトリにあったファイル（ファイル名 → 中身）
    var directoryContentsDuringRun: [[String: Data]] = []
}

/// 起動したコマンドを記録するだけで、実際には起動しない。ループの状態はテストから変える
final class FakeRuntime: LoopRuntime {
    let state = OSAllocatedUnfairLock(initialState: FakeRuntimeState())
    /// `run` を、テストが決めた時まで返さないようにする（`OrchestratorTestDoubles+RunGate.swift`）
    let runGate = RunGate()

    var launched: [[String]] {
        state.withLock { $0.launched }
    }

    var launchEnvironments: [[String: String]] {
        state.withLock { $0.launchEnvironments }
    }

    func set(_ status: LoopStatus) {
        state.withLock { $0.status = status }
    }

    func setLaunchFails(_ fails: Bool) {
        state.withLock { $0.launchFails = fails }
    }

    func status(of repository: RepositoryConfig) async -> LoopStatus {
        state.withLock { $0.status }
    }

    func launch(_ arguments: [String], environment: [String: String], for repository: RepositoryConfig) async throws {
        try state.withLock { state in
            if state.launchFails {
                throw TestError()
            }
            state.launched.append(arguments)
            state.launchEnvironments.append(environment)
            // 起動したプロセスは、テストが状態を変えるまで生きている
            state.status = LoopStatus(stateFileExists: false, processAlive: true)
        }
    }

    func setEpic(_ epic: EpicSnapshot) {
        state.withLock { $0.epic = epic }
    }

    func setUsageLimitReset(_ date: Date?) {
        state.withLock { $0.usageLimitReset = date }
    }

    func usageLimitReset(of repository: RepositoryConfig) async -> Date? {
        state.withLock { $0.usageLimitReset }
    }

    func setHungLoop(_ loop: HungLoop?) {
        state.withLock { $0.hungLoop = loop }
    }

    var terminated: [HungLoop] {
        state.withLock { $0.terminated }
    }

    func hungLoop(of repository: RepositoryConfig, timeout: Duration, now: Date) async -> HungLoop? {
        state.withLock { $0.hungLoop }
    }

    var clearedNoTasksMarkers: Int {
        state.withLock { $0.clearedNoTasksMarkers }
    }

    func clearNoTasksMarker(of repository: RepositoryConfig) async {
        state.withLock { state in
            state.clearedNoTasksMarkers += 1
            state.epic = EpicSnapshot(
                branch: state.epic.branch,
                goal: state.epic.goal,
                state: state.epic.state,
                discussion: state.epic.discussion,
                loopPrepared: state.epic.loopPrepared
            )
        }
    }

    func terminate(_ loop: HungLoop) async {
        state.withLock { state in
            state.terminated.append(loop)
            // 止めたプロセスは終わり、state ファイルだけが残る（異常終了）
            state.hungLoop = nil
            state.status = LoopStatus(stateFileExists: false, processAlive: false, stalled: true)
        }
    }

    func epicSnapshot(of repository: RepositoryConfig) async -> EpicSnapshot {
        state.withLock { $0.epic }
    }

    func setLastActivity(_ date: Date?) {
        state.withLock { $0.lastActivity = date }
    }

    func lastActivity(of repository: RepositoryConfig) async -> Date? {
        state.withLock { $0.lastActivity }
    }

    func setRunResults(_ results: [CommandResult]) {
        state.withLock { $0.runResults = results }
    }

    var ran: [[String]] {
        state.withLock { $0.ran }
    }

    var ranFor: [String] {
        state.withLock { $0.ranFor }
    }

    var inputs: [String] {
        state.withLock { $0.inputs }
    }

    var runEnvironments: [[String: String]] {
        state.withLock { $0.runEnvironments }
    }

    func run(
        _ arguments: [String],
        input: String,
        environment: [String: String],
        for repository: RepositoryConfig,
        timeout: Duration
    ) async throws -> CommandResult {
        // 依頼の添付を置いたディレクトリ（{attachmentsPath}）の中身を、claude が読む時点のものとして記録する
        let snapshot = Self.directoryContents(in: arguments)
        let result = state.withLock { state in
            state.directoryContentsDuringRun.append(snapshot)
            state.ran.append(arguments)
            state.ranFor.append(repository.fullName)
            state.inputs.append(input)
            state.runEnvironments.append(environment)
            let result = state.runResults[0]
            if state.runResults.count > 1 {
                state.runResults.removeFirst()
            }
            return result
        }
        await runGate.pass()
        return result
    }
}
