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

    /// 依頼の人の意図から決める epic の id
    public static func epicID(for intent: IntentReference) -> ULID {
        .derived(from: intent.nonce, seed: "\(intent.keyId)/epic")
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
