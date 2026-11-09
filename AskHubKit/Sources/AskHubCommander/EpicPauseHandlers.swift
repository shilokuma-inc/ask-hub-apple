import AskHubProtocol
import Foundation

// 開始した epic の一時停止・再開・ほかの Mac への引き継ぎ（`docs/renewal/operations.md` の「Mac の一時停止・再開・引き継ぎ」）。
// どれも epic のファイルだけを書き換え、ジョブは同じ周の `JobSweep` が `EpicHold` で動かす（止める・戻す・付け替える）

/// 一時停止（`pauseEpic`）を受け付け、epic に一時停止の印を付ける。開始した後（実装・最終 PR の段取り・人の確認の待ち）だけ受け付ける。
/// 動いているジョブは最後まで終わらせ、まだ動いていないジョブは止め、次のジョブを作らない（`TaskFlow` は印の付いた epic を進めない）
public struct PauseEpicHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let pause: PauseEpicIntent
        do {
            pause = try PauseEpicIntent(envelope: envelope)
        } catch {
            return .reject("一時停止の形が違う（\(error.detail)）")
        }
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(pause.repo, pause.epic)) else {
            return .reject("epic が無い")
        }
        // 前の周で印を付けた（やり直し）か、一時停止の中でもう一度止めた
        if epic.pause != nil { return .accept }
        guard TaskFlow.stages.contains(epic.stage) else { return .reject("開始した後だけ一時停止できる（今は \(epic.stage.rawValue)）") }
        let mark = EpicFile.Pause(since: context.timestamp, origin: pause.intent)
        try await context.updateEpic(epic, message: "epic を一時停止する") { file in
            guard TaskFlow.stages.contains(file.stage), file.pause == nil else { return false }
            file.pause = mark
            return true
        }
        return .accept
    }
}

/// 再開（`resumeEpic`）を受け付け、一時停止の印を外す。一時停止で止めたジョブは `assigned` に戻り、次のジョブを作るのも再開する。
/// Mac がオフラインで止まったジョブは、同じ Mac が戻るのを待つ（再開では動かさない）
public struct ResumeEpicHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let resume: ResumeEpicIntent
        do {
            resume = try ResumeEpicIntent(envelope: envelope)
        } catch {
            return .reject("再開の形が違う（\(error.detail)）")
        }
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(resume.repo, resume.epic)) else {
            return .reject("epic が無い")
        }
        // 前の周で印を外した（やり直し）か、止めていない
        guard epic.pause != nil else { return .accept }
        try await context.updateEpic(epic, message: "epic を再開する") { file in
            guard file.pause != nil else { return false }
            file.pause = nil
            return true
        }
        return .accept
    }
}

/// ほかの Mac への引き継ぎ（`handover`）を受け付け、epic の Mac を移す先に書き換える。移す先はオフラインでもよい（戻ったら続きから動く）。
///
/// 一時停止中か、epic の Mac で動いているジョブが無いときだけ受け付ける（動いている作業を、知らないうちに捨てない）。
/// 動いていないジョブは、同じ周の `JobSweep` が移す先に付け替える。一時停止中に前の Mac で最後まで動いたジョブも、
/// 終わった後にやり直すなら移す先に付け替わる。移す先の Mac は、作業ブランチ（最後に push したところ）から作業場所を取り出す
public struct HandoverHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let handover: HandoverIntent
        do {
            handover = try HandoverIntent(envelope: envelope)
        } catch {
            return .reject("引き継ぎの形が違う（\(error.detail)）")
        }
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(handover.repo, handover.epic)) else {
            return .reject("epic が無い")
        }
        // 前の周で書き換えた（やり直し）か、今の Mac を選んだ
        if epic.mac == handover.mac { return .accept }
        guard TaskFlow.stages.contains(epic.stage), let current = epic.mac else {
            return .reject("開始した後だけ引き継げる（今は \(epic.stage.rawValue)）")
        }
        guard try await context.read(MacFile.self, at: StatePath.mac(handover.mac)) != nil else {
            return .reject("Mac \(handover.mac) が登録されていない（ワーカーが一度も動いていない）")
        }
        if epic.pause == nil, let problem = try await runningProblem(of: epic, on: current, in: context) { return .reject(problem) }
        try await context.updateEpic(epic, message: "epic を \(handover.mac) に引き継ぐ") { file in
            guard TaskFlow.stages.contains(file.stage), file.mac == current else { return false }
            file.mac = handover.mac
            return true
        }
        return .accept
    }

    /// 一時停止していない epic で、前の Mac で動いているジョブがあれば、断る理由
    private func runningProblem(of epic: EpicFile, on mac: MacName, in context: CommanderContext) async throws(CommanderError) -> String? {
        let list = try await context.jobList(epic.repo, epic: epic.id)
        guard list.unreadable.isEmpty else { return "読めないジョブがあり、動いているジョブを確かめられない（司令塔を新しくする）" }
        let running = list.jobs.filter { $0.state == .running && $0.assignedMac == mac }
        guard !running.isEmpty else { return nil }
        let kinds = running.map(\.kind.rawValue).joined(separator: "・")
        return "\(mac) でジョブ（\(kinds)）が動いている。一時停止して、動いているジョブが終わってから引き継ぐ"
    }
}

extension CommanderContext {
    /// epic のファイルを、読んだ後に段階などが変わっていないかを `change` で確かめながら書き換える（更新の時刻も書く）。
    /// `change` が false を返したら書かずに、次の周に回す（ほかの処理が先に書き換えた）
    func updateEpic(
        _ epic: EpicFile,
        message: String,
        change: @escaping @Sendable (inout EpicFile) -> Bool
    ) async throws(CommanderError) {
        let now = timestamp
        let path = StatePath.epic(epic.repo, epic.id)
        var written = false
        do {
            try await files.update(EpicFile.self, at: path, message: message) { file in
                guard change(&file) else { return false }
                file.updatedAt = now
                written = true
                return true
            }
        } catch {
            throw .files(error)
        }
        guard written else { throw .changedWhileProcessing(path) }
    }
}
