import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation

/// 依頼（`request`）を受け付け、epic と質問づくりのジョブを作る（`docs/renewal/flows.md` の「司令塔の動き」の表）。
///
/// epic の id は依頼の人の意図から決めるので、途中で止まってやり直しても、同じ epic とジョブを 2 つ作らない
public struct RequestHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let request: RequestIntent
        do {
            request = try RequestIntent(envelope: envelope)
        } catch {
            return .reject("依頼の形が違う（\(error.detail)）")
        }
        guard try await context.read(RepositoryFile.self, at: StatePath.repository(request.repo)) != nil else {
            return .reject("\(request.repo) は対象のリポジトリに加えていない")
        }
        // 添付は確かめること（protocol.md の 3）なので、合わなければ記録を作らずに残す（置き直せば次の周で受け付ける）
        if let problem = try await attachmentProblem(of: request, in: context) { return .ignore(problem) }
        let epic = EpicFile(
            id: Self.epicID(for: request.intent),
            repo: request.repo,
            title: request.title,
            stage: .drafting,
            origin: request.intent,
            createdAt: context.timestamp,
            updatedAt: context.timestamp
        )
        do {
            try await context.files.create(epic, at: StatePath.epic(epic.repo, epic.id), message: "epic を作る")
        } catch .alreadyExists {
            // 前の周で作った（やり直し）
        } catch {
            throw .files(error)
        }
        // 依頼の中身（題・本文・添付）は、ジョブを実行するときに元の意図から読む
        try await context.create(context.claudeJob(.makeQuestions, for: epic, origin: request.intent, seed: "", input: [:]))
        return .accept
    }

    /// 依頼の人の意図から決める epic の id（決め方は `RequestIntent.epicID(for:)`。クライアントと同じ）
    public static func epicID(for intent: IntentReference) -> ULID {
        RequestIntent.epicID(for: intent)
    }

    /// 添付は、依頼の意図より先に置く。置いた中身の大きさとハッシュが、署名した封筒と合うかを確かめる
    private func attachmentProblem(of request: RequestIntent, in context: CommanderContext) async throws(CommanderError) -> String? {
        for attachment in request.attachments {
            let path = StatePath.attachment(device: request.intent.keyId, nonce: request.intent.nonce, number: attachment.number)
            let blob: StoredBlob?
            do {
                blob = try await context.store.read(path)
            } catch {
                throw .store(error)
            }
            guard let data = blob?.data else { return "添付 \(attachment.number)（\(attachment.name)）が無い" }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == attachment.size, digest == attachment.sha256 else {
                return "添付 \(attachment.number)（\(attachment.name)）の大きさかハッシュが、依頼と合わない"
            }
        }
        return nil
    }
}

/// 開始（`startEpic`）を受け付け、epic を `running` にして、選ばれた Mac に作業場所の準備のジョブを作る
public struct StartEpicHandler: IntentHandler {
    public var timing: JobTiming

    public init(timing: JobTiming = JobTiming()) {
        self.timing = timing
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let start: StartEpicIntent
        do {
            start = try StartEpicIntent(envelope: envelope)
        } catch {
            return .reject("開始の形が違う（\(error.detail)）")
        }
        let target = start.target
        let epicPath = StatePath.epic(target.repo, target.epic)
        guard let epic = try await context.read(EpicFile.self, at: epicPath) else { return .reject("epic が無い") }
        // 前の周で開始まで書いた（やり直し）
        if epic.stage == .running, epic.mac == start.mac, epic.goalVersion == target.version { return .accept }
        if let problem = try await problem(starting: epic, with: start, in: context) { return .reject(problem) }

        let spec = JobSpec(kind: .prepareWorkspace, mac: start.mac, needs: .init(claude: false, build: false))
        let job = context.job(spec, for: epic, origin: start.intent, seed: "")
        try await context.create(job)
        let now = context.timestamp
        do {
            try await context.files.update(EpicFile.self, at: StatePath.epic(epic.repo, epic.id), message: "epic を開始する") {
                guard $0.stage == .awaitingStart else { return false }
                $0.stage = .running
                $0.mac = start.mac
                $0.goalVersion = target.version
                $0.updatedAt = now
                return true
            }
        } catch {
            throw .files(error)
        }
        return .accept
    }

    /// 開始できない理由。開始できれば nil
    private func problem(
        starting epic: EpicFile,
        with start: StartEpicIntent,
        in context: CommanderContext
    ) async throws(CommanderError) -> String? {
        guard epic.stage == .awaitingStart else { return "開始できる段階でない（今は \(epic.stage.rawValue)）" }
        let goal = try await context.read(GoalFile.self, at: StatePath.goal(epic.repo, epic.id))
        guard let goal else { return "ゴールが無い" }
        guard goal.version == start.target.version else { return "ゴールが直された（今の版は \(goal.version)）。新しいゴールを確かめて開始し直す" }
        switch try await context.hasOpenJob(epic.repo, epic: epic.id, where: { $0.kind == .reviseGoal }) {
        case true?: return "ゴールを直している途中。直し終えてから開始する"
        case nil: return Self.unreadableJobs
        case false?: break
        }
        guard let mac = try await context.read(MacFile.self, at: StatePath.mac(start.mac)) else { return "Mac \(start.mac) が登録されていない" }
        if context.now().timeIntervalSince(mac.seenAt.date) > TimeInterval(timing.macStaleAfter.components.seconds) {
            return "Mac \(start.mac) がオフライン（最後の生きている印は \(mac.seenAt)）"
        }
        let limit = try await context.read(RepositoryFile.self, at: StatePath.repository(epic.repo))?.maxConcurrentEpics ?? 1
        guard let running = try await runningEpics(of: epic.repo, except: epic.id, in: context) else {
            return "読めない epic があり、同時に回している数を確かめられない（司令塔を新しくする）"
        }
        if running >= limit { return "同時に回せる epic の上限（\(limit) 本）に達している。ほかの epic が終わってから開始する" }
        return nil
    }

    static let unreadableJobs = "読めないジョブがあり、ゴールを直している途中かを確かめられない（司令塔を新しくする）"

    /// 回している（実装・最終 PR・確認の待ち）epic の数。読めない（知らない版など）epic があれば、数えられないので nil
    private func runningEpics(
        of repo: RepositoryFullName,
        except id: ULID,
        in context: CommanderContext
    ) async throws(CommanderError) -> Int? {
        let entries: [DirectoryEntry]
        do {
            // epic のディレクトリは消さずに増えるので、1,000 件で切れる `list` ではなく `listAll` で直下をすべて読む
            // （下の階層まで読むと、各 epic のジョブと試行まで読んで大きすぎる）
            entries = try await context.store.listAll(StatePath.epics(repo)) ?? []
        } catch {
            throw .store(error)
        }
        var count = 0
        for entry in entries where entry.kind == .directory {
            guard let epicID = ULID(rawValue: entry.name), epicID != id else { continue }
            let epic: EpicFile?
            do {
                epic = try await context.files.read(EpicFile.self, at: StatePath.epic(repo, epicID))?.file
            } catch .unreadable {
                return nil
            } catch {
                throw .files(error)
            }
            if let epic, [.running, .finalizing, .reviewing].contains(epic.stage) { count += 1 }
        }
        return count
    }
}

/// ゴールの修正（`reviseGoal`）を受け付け、ゴールを直すジョブを作る
public struct ReviseGoalHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let revise: ReviseGoalIntent
        do {
            revise = try ReviseGoalIntent(envelope: envelope)
        } catch {
            return .reject("ゴールの修正の形が違う（\(error.detail)）")
        }
        let target = revise.target
        let epicPath = StatePath.epic(target.repo, target.epic)
        guard let epic = try await context.read(EpicFile.self, at: epicPath) else { return .reject("epic が無い") }
        guard epic.stage == .awaitingStart else { return .reject("ゴールを直せる段階でない（今は \(epic.stage.rawValue)）") }
        guard let goal = try await context.read(GoalFile.self, at: StatePath.goal(epic.repo, epic.id)) else { return .reject("ゴールが無い") }
        guard goal.version == target.version else { return .reject("ゴールが直された（今の版は \(goal.version)）。新しいゴールに指示し直す") }
        switch try await context.hasOpenJob(epic.repo, epic: epic.id, where: { $0.kind == .reviseGoal && $0.origin != revise.intent }) {
        case true?: return .reject("ほかの指示でゴールを直している途中。直し終えてから指示し直す")
        case nil: return .reject(StartEpicHandler.unreadableJobs)
        case false?: break
        }
        let input: [String: JSONValue] = ["instruction": .string(revise.instruction), "goalVersion": .integer(Int64(target.version))]
        try await context.create(context.claudeJob(.reviseGoal, for: epic, origin: revise.intent, seed: "", input: input))
        return .accept
    }
}

/// 分け方の判断（`decideSplit`）を受け付ける。分けて依頼し直すなら epic をやめ、このまま 1 つで進めるなら、
/// 大きすぎるとは返させない着手前の確認のジョブを作る（`docs/renewal/flows.md` の「着手前の確認とゴール」）
public struct DecideSplitHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let decide: DecideSplitIntent
        do {
            decide = try DecideSplitIntent(envelope: envelope)
        } catch {
            return .reject("分け方の判断の形が違う（\(error.detail)）")
        }
        let target = decide.target
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(target.repo, target.epic)) else {
            return .reject("epic が無い")
        }
        let readiness = try await context.read(ReadinessFile.self, at: StatePath.readiness(epic.repo, epic.id))
        let check = context.claudeJob(.checkReadiness, for: epic, origin: decide.intent, seed: "", input: ["proceed": .bool(true)])
        // 前の周で epic まで書いた（やり直し）
        if try await alreadyApplied(decide, to: epic, readiness: readiness, check: check, in: context) { return .accept }
        guard epic.stage == .awaitingSplit else { return .reject("分け方を選べる段階でない（今は \(epic.stage.rawValue)）") }
        guard let readiness, readiness.verdict == .tooLarge, readiness.version == target.version else {
            return .reject("着手前の確認の結果が変わった。新しい結果を確かめて選び直す")
        }
        switch decide.choice {
        case .split:
            // 分けた依頼は、クライアントが分け方の案から下書きを出し、人が確かめて送る。動いているジョブ（説明など）は止める
            try await context.cancelJobs(epic.repo, epic: epic.id) { _ in true }
            try await context.setStage(.abandoned, of: epic, from: [.awaitingSplit])
        case .proceed:
            // 決めたことを確認の結果に残す（確認のジョブが答え直しで取り消されても、後の確認に引き継ぐ）
            try await markProceeding(epic, version: target.version, in: context)
            try await context.create(check)
            try await context.setStage(.checking, of: epic, from: [.awaitingSplit])
        }
        return .accept
    }

    private func markProceeding(_ epic: EpicFile, version: Int, in context: CommanderContext) async throws(CommanderError) {
        do {
            try await context.files.update(ReadinessFile.self, at: StatePath.readiness(epic.repo, epic.id), message: "このまま 1 つで進める") {
                guard $0.version == version, $0.proceeding != true else { return false }
                $0.proceeding = true
                return true
            }
        } catch {
            throw .files(error)
        }
    }

    private func alreadyApplied(
        _ decide: DecideSplitIntent,
        to epic: EpicFile,
        readiness: ReadinessFile?,
        check: JobFile,
        in context: CommanderContext
    ) async throws(CommanderError) -> Bool {
        switch decide.choice {
        case .split:
            return epic.stage == .abandoned && readiness?.version == decide.target.version
        case .proceed:
            guard epic.stage != .awaitingSplit else { return false }
            return try await context.read(JobFile.self, at: StatePath.job(epic.repo, epic: epic.id, job: check.id)) != nil
        }
    }
}

/// 対象に加える（`addRepository`）を受け付け、`repo.json` を作る。段階 2 では設定を書くだけで、GitHub 側の準備（保護・Discussions）は後で足す
public struct AddRepositoryHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let add: AddRepositoryIntent
        do {
            add = try AddRepositoryIntent(envelope: envelope)
        } catch {
            return .reject("対象に加える意図の形が違う（\(error.detail)）")
        }
        // 同時に回す epic は、最初の版では 1 本（ユーザーの決定）
        let file = RepositoryFile(repo: add.repo, platform: add.platform, maxConcurrentEpics: 1, addedAt: context.timestamp)
        do {
            try await context.files.create(file, at: StatePath.repository(add.repo), message: "\(add.repo) を対象に加える")
        } catch .alreadyExists {
            // 加え済み（やり直し、または同じリポジトリを加え直した）
        } catch {
            throw .files(error)
        }
        return .accept
    }
}

/// 取り下げ（`abandonEpic`）を受け付ける。開始する前の epic を `abandoned` にし、終わっていないジョブを取り消す。
/// 動いている Claude のジョブは、結果を書く前に epic を読み直して捨てる。開始した後の取り下げ（作業のブランチの片付けなど）は段階 3 で決める
public struct AbandonEpicHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let abandon: AbandonEpicIntent
        do {
            abandon = try AbandonEpicIntent(envelope: envelope)
        } catch {
            return .reject("取り下げの形が違う（\(error.detail)）")
        }
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(abandon.repo, abandon.epic)) else {
            return .reject("epic が無い")
        }
        switch epic.stage {
        case .abandoned:
            // 前の周でやめた（ジョブの片付けの途中で止まった）か、ほかの理由でやめていた
            break
        case let stage where CommanderContext.planningStages.contains(stage):
            try await context.setStage(.abandoned, of: epic, from: CommanderContext.planningStages)
        default:
            return .reject("開始した後は取り下げられない（今は \(epic.stage.rawValue)）")
        }
        try await context.cancelJobs(epic.repo, epic: epic.id) { _ in true }
        return .accept
    }
}
