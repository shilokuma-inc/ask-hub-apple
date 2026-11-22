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
        guard let repository = try await context.read(RepositoryFile.self, at: StatePath.repository(request.repo)) else {
            return .reject("\(request.repo) は対象のリポジトリに加えていない")
        }
        guard !repository.isRemoved else { return .reject("\(request.repo) は対象から外した。依頼するには加え直す") }
        if let release = request.release, let problem = try await Self.releaseProblem(release, of: request.repo, in: context) {
            // 前の周で epic を作った後に、リリースが終わった（やり直し）
            guard try await context.read(EpicFile.self, at: StatePath.epic(request.repo, Self.epicID(for: request.intent))) != nil else {
                return .reject(problem)
            }
        }
        // 添付は確かめること（protocol.md の 3）なので、合わなければ記録を作らずに残す（置き直せば次の周で受け付ける）
        if let problem = try await Self.attachmentProblem(request.attachments, of: request.intent, in: context) { return .ignore(problem) }
        let epic = EpicFile(
            id: Self.epicID(for: request.intent),
            repo: request.repo,
            title: request.title,
            stage: .drafting,
            origin: request.intent,
            release: request.release,
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

    /// 「このリリースを直す」依頼を受け付けられない理由。直す先は、AskHub で始めた終わっていないリリースで、release ブランチを作ったものだけ
    /// （作業ブランチを release ブランチから作り、最終 PR を release ブランチに向けるため）。受け付けられれば nil
    static func releaseProblem(
        _ release: MarketingVersion,
        of repo: RepositoryFullName,
        in context: CommanderContext
    ) async throws(CommanderError) -> String? {
        guard let submission = try await context.read(SubmissionFile.self, at: StatePath.submission(repo, release)) else {
            return "\(release) のリリースを始めていない"
        }
        if submission.isEnded { return "\(release) のリリースはもう終わっている。次のリリースで直す（ふだんの依頼にする）" }
        if submission.origin != .askhub { return "\(release) は App Store Connect で手で審査に出した版。AskHub で始めたリリースだけを直せる" }
        if submission.branch == nil { return "\(release) の release ブランチがまだ無い。作られてから依頼する" }
        return nil
    }

    /// 依頼の人の意図から決める epic の id（決め方は `RequestIntent.epicID(for:)`。クライアントと同じ）
    public static func epicID(for intent: IntentReference) -> ULID {
        RequestIntent.epicID(for: intent)
    }

    /// 添付は、意図より先に置く。置いた中身の大きさとハッシュが、署名した封筒と合うかを確かめる（依頼・リジェクトの理由）
    static func attachmentProblem(
        _ attachments: [RequestAttachment],
        of intent: IntentReference,
        in context: CommanderContext
    ) async throws(CommanderError) -> String? {
        for attachment in attachments {
            let path = StatePath.attachment(device: intent.keyId, nonce: intent.nonce, number: attachment.number)
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
        let repository = try await context.read(RepositoryFile.self, at: StatePath.repository(epic.repo))
        if let problem = Self.repositoryProblem(repository, of: epic.repo) { return problem }
        let goal = try await context.read(GoalFile.self, at: StatePath.goal(epic.repo, epic.id))
        guard let goal else { return "ゴールが無い" }
        guard goal.version == start.target.version else { return "ゴールが直された（今の版は \(goal.version)）。新しいゴールを確かめて開始し直す" }
        switch try await context.hasOpenJob(epic.repo, epic: epic.id, where: { $0.kind == .reviseGoal }) {
        case true?: return "ゴールを直している途中。直し終えてから開始する"
        case nil: return Self.unreadableJobs
        case false?: break
        }
        if let problem = try await macProblem(start.mac, in: context) { return problem }
        let limit = repository?.maxConcurrentEpics ?? 1
        guard let running = try await runningEpics(of: epic.repo, except: epic.id, in: context) else {
            return "読めない epic があり、同時に回している数を確かめられない（司令塔を新しくする）"
        }
        if running >= limit { return "同時に回せる epic の上限（\(limit) 本）に達している。ほかの epic が終わってから開始する" }
        return nil
    }

    /// リポジトリの設定で始められない理由。始められれば nil
    private static func repositoryProblem(_ repository: RepositoryFile?, of repo: RepositoryFullName) -> String? {
        if repository?.isRemoved == true { return "\(repo) は対象から外した。開始するには加え直す" }
        // ワーカーはビルドの設定でビルド・テストし、子 PR と最終 PR のチェックを待つので、無ければ始めない
        guard repository?.build != nil else { return "\(repo) のビルドの設定（repo.json の build）が無い。設定を入れてから開始する" }
        return nil
    }

    /// 選ばれた Mac で始められない理由（登録されていない・オフライン・空きが少ない）。始められれば nil
    private func macProblem(_ name: MacName, in context: CommanderContext) async throws(CommanderError) -> String? {
        guard let mac = try await context.read(MacFile.self, at: StatePath.mac(name)) else { return "Mac \(name) が登録されていない" }
        if context.now().timeIntervalSince(mac.seenAt.date) > TimeInterval(timing.macStaleAfter.components.seconds) {
            return "Mac \(name) がオフライン（最後の生きている印は \(mac.seenAt)）"
        }
        if mac.isLowOnDisk { return mac.lowDiskProblem(doing: "開始する") }
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

/// 対象に加える（`addRepository`）を受け付け、`repo.json` を作る。管理用のトークンを持つ司令塔なら、続けて GitHub 側の準備
/// （Discussions・ワークフローの直しの PR。`RepositorySetupStep`）を流す。保護は掛けない（人が保護の設定を押したときだけ）
public struct AddRepositoryHandler: IntentHandler {
    /// GitHub 側の準備に使う管理用のトークン。nil（ワーカー・テスト）なら準備を流さない
    public var admin: AdminGitHub?

    public init(admin: AdminGitHub? = nil) {
        self.admin = admin
    }

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let add: AddRepositoryIntent
        do {
            add = try AddRepositoryIntent(envelope: envelope)
        } catch {
            return .reject("対象に加える意図の形が違う（\(error.detail)）")
        }
        // 同時に回す epic は、最初の版では 1 本（ユーザーの決定）
        let file = RepositoryFile(repo: add.repo, platform: add.platform, maxConcurrentEpics: 1, addedAt: context.timestamp)
        let path = StatePath.repository(add.repo)
        do {
            try await context.files.create(file, at: path, message: "\(add.repo) を対象に加える")
        } catch .alreadyExists {
            // 加え済み（やり直し、または同じリポジトリを加え直した）。対象から外していたら、印を外して戻す（ビルドの設定などはそのまま）
            do {
                try await context.files.update(RepositoryFile.self, at: path, message: "\(add.repo) を対象に加え直す") {
                    guard $0.isRemoved else { return false }
                    $0.removedAt = nil
                    return true
                }
            } catch {
                throw .files(error)
            }
        } catch {
            throw .files(error)
        }
        // 加え直したとき（準備をやり直す）も流す。準備が止まっても、加えるのは受け付ける
        if let admin { try await RepositorySetupStep(admin: admin).run(for: add.repo, in: context) }
        return .accept
    }
}

/// 取り下げ（`abandonEpic`）を受け付ける。epic を `abandoned` にし、終わっていないジョブを取り消す（`docs/renewal/flows.md` の「司令塔の動き」）。
///
/// 動いている Claude のジョブは、結果を書く前に epic を読み直して捨てる。開始した後の epic の開いている子 PR と最終 PR は、
/// 周の最後に `AbandonedPullRequests` が閉じる（作業ブランチと子ブランチは消さない）。マージした epic と、最終 PR をマージしている途中の epic は断る
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
        case .merged:
            return .reject("マージした epic は取り下げられない")
        default:
            // 最終 PR をマージしているジョブ（動いている・終えたがまだ merged にしていない）があれば、マージは取り消せないので断る
            let merging = try await context.jobList(epic.repo, epic: epic.id).jobs.contains { job in
                job.kind == .mergeFinalPullRequest && [.running, .succeeded].contains(job.state)
            }
            if merging { return .reject("最終 PR をマージしている途中なので取り下げられない") }
            try await context.abandon(epic)
        }
        try await context.cancelJobs(epic.repo, epic: epic.id) { _ in true }
        return .accept
    }
}
