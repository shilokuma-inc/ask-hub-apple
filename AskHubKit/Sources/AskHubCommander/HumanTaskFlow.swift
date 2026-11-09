import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation

/// 人がする作業を終えた（`humanTaskDone`）を受け付ける（`docs/renewal/flows.md` の「人がする作業」）。
///
/// 決まった確かめだけをして（ユーザーの決定）、作業を `done` にし、誰が・いつ・どのファイルで終えたかを `done` に書く。
/// 同じ書き込みで、依存する人がする作業がすべて `done` になったタスクを `locked` から `pending` に戻す。その後は、いつもどおり `TaskFlow` が次のタスクを進める
///
/// - 渡すファイルは、依頼の添付と同じく意図より先に置かれる。大きさかハッシュが署名した封筒と合わなければ、記録を作らずに残す（`protocol.md` の確かめることの 3）
/// - ゴールの版・作業が `pending`・渡すものの種類（`file` はファイルが 1 つ、`none`・`secret` はファイルなし）が合わなければ断る。
///   `secret` は、人が GitHub の設定画面で Secrets に入れてから「終わった」を押す（値は受け取らない。Secrets に入れる仕組みは後で作る）
public struct HumanTaskDoneHandler: IntentHandler {
    /// 終えたことを受け付ける段階。開始の前（ゴールの確認の間）に終えてもよい。
    /// 開始の前にゴールを直すと、作り直したゴールでは作業が `pending` に戻る（直したゴールの作業を、もう一度終えてもらう）
    static let stages: Set<EpicStage> = [.awaitingStart, .running]

    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let done: HumanTaskDoneIntent
        do {
            done = try HumanTaskDoneIntent(envelope: envelope)
        } catch {
            return .reject("人がする作業を終えた意図の形が違う（\(error.detail)）")
        }
        if let file = done.file, let problem = try await Self.fileProblem(file, of: done.intent, in: context) { return .ignore(problem) }
        let target = done.target
        let epicPath = StatePath.epic(target.repo, target.epic)
        guard let epic = try await context.read(EpicFile.self, at: epicPath) else { return .reject("epic が無い") }
        let path = StatePath.goal(target.repo, target.epic)
        guard let goal = try await context.read(GoalFile.self, at: path) else { return .reject("ゴールが無い") }
        guard let task = goal.humanTasks.first(where: { $0.id == target.task }) else { return .reject("人がする作業 \(target.task) が無い") }
        // 前の周で終えたことを書いた（やり直し）
        if task.done?.intent == done.intent { return .accept }
        if let problem = problem(completing: task, with: done, epic: epic, goal: goal) { return .reject(problem) }
        let completion = GoalFile.Completion(intent: done.intent, at: context.timestamp, file: done.file)
        let saved: GoalFile
        do {
            saved = try await context.files.update(GoalFile.self, at: path, message: "人がする作業 \(task.id) を終える") { goal in
                goal.complete(task.id, with: completion, version: target.goalVersion)
            }.file
        } catch {
            throw .files(error)
        }
        // 読んだ後に書き換わった（ほかの意図で終えた・ゴールが直された）。次の周で読み直して決める
        guard saved.humanTasks.contains(where: { $0.id == task.id && $0.done == completion }) else { throw .changedWhileProcessing(path) }
        return .accept
    }

    /// 受け付けられない理由。受け付けられれば nil
    private func problem(completing task: GoalFile.HumanTask, with done: HumanTaskDoneIntent, epic: EpicFile, goal: GoalFile) -> String? {
        guard Self.stages.contains(epic.stage) else { return "人がする作業を終えられる段階でない（今は \(epic.stage.rawValue)）" }
        guard goal.version == done.target.goalVersion else { return "ゴールが直された（今の版は \(goal.version)）。新しいゴールを見てから送り直す" }
        guard task.state == .pending else { return "人がする作業 \(task.id) はもう終えている" }
        switch (task.handover.kind, done.file) {
        case (.file, nil): return "人がする作業 \(task.id) はファイルを渡す作業なのに、ファイルが無い"
        case (.none, _?), (.secret, _?): return "人がする作業 \(task.id) はファイルを渡さない作業なのに、ファイルがある"
        case (.file, _?), (.none, nil), (.secret, nil): return nil
        }
    }

    /// 渡すファイルの中身が置かれていて、大きさとハッシュが署名した封筒と合うか。合えば nil
    static func fileProblem(
        _ file: RequestAttachment,
        of intent: IntentReference,
        in context: CommanderContext
    ) async throws(CommanderError) -> String? {
        let blob: StoredBlob?
        do {
            blob = try await context.store.read(StatePath.attachment(device: intent.keyId, nonce: intent.nonce, number: file.number))
        } catch {
            throw .store(error)
        }
        guard let data = blob?.data else { return "渡すファイル（\(file.name)）が無い" }
        guard data.count == file.size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
            return "渡すファイル（\(file.name)）の大きさかハッシュが、署名した意図と合わない"
        }
        return nil
    }
}

extension TaskFlow {
    /// タスクがすべて済んだ: 人がする作業もすべて済んでいれば、最終 PR の段取りに進む。どのタスクも依存していない作業が残っていれば、終わるのを待つ
    func startFinalAfterHumanTasks(_ goal: GoalFile, plan: Plan, jobs: [JobFile]) async throws(CommanderError) -> Advanced {
        let waiting = goal.humanTasks.filter { $0.state != .done }.map(\.id)
        guard waiting.isEmpty else {
            return Advanced(notes: ["epic \(plan.epic.id) のタスクはすべて済んだ。人がする作業（\(waiting.joined(separator: "・"))）が終わるのを待つ"])
        }
        return try await startFinal(goal, plan: plan, jobs: jobs)
    }
}

extension GoalFile {
    /// 人がする作業を終えたことにし、ロックを外せるタスクを `pending` に戻す。ゴールの版が `version` で、作業が `pending` のときだけ変える。
    /// 人が読むゴールの中身は変えないので、ゴールの版は上げない
    mutating func complete(_ humanTask: String, with completion: Completion, version: Int) -> Bool {
        guard self.version == version, let index = humanTasks.firstIndex(where: { $0.id == humanTask }),
              humanTasks[index].state == .pending else {
            return false
        }
        humanTasks[index].state = .done
        humanTasks[index].done = completion
        unlockTasks()
        return true
    }

    /// 依存する人がする作業がすべて `done` になったタスクを `locked` から `pending` に戻す。`locked` は人がする作業への依存だけで決めるので、
    /// ほかのタスクへの依存が残っていても戻す（ほかのタスクへの依存は、次のタスクを選ぶときに見る）
    mutating func unlockTasks() {
        let humanTaskIDs = Set(humanTasks.map(\.id))
        let finished = Set(humanTasks.filter { $0.state == .done }.map(\.id))
        for index in tasks.indices where tasks[index].state == .locked {
            if tasks[index].dependsOn.filter(humanTaskIDs.contains).allSatisfy(finished.contains) { tasks[index].state = .pending }
        }
    }
}
