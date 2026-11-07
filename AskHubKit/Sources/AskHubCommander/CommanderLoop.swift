import AskHubClaude
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 常時オンの Mac の司令塔とワーカーの常駐のループ（`docs/renewal/flows.md` の「司令塔の動き」）。
///
/// 1 周ごとに、人の意図を処理し終えてから、試行を読んでジョブの状態を決め、自分宛ての Claude のジョブを引き受けて並んで動かし、
/// 進行を止めているものを知らせる。最後に、状態を Discussion の写しと照らし合わせる（写しに失敗しても、周は止めない）。
/// 生きている印（`commander.json`・`macs/<mac>.json`）は、決めた間隔で書く
public actor CommanderLoop {
    public struct Settings: Sendable {
        /// 1 周の間隔（`intents/` は ETag つきで読むので、変わっていなければ上限に数えられない）
        public var pollInterval: Duration
        /// 生きている印を書く間隔
        public var heartbeatInterval: Duration
        /// この Mac で同時に動かす数
        public var capacity: MacFile.Capacity
        public var commanderVersion: String
        public var claudeVersion: String?

        public init(
            capacity: MacFile.Capacity,
            commanderVersion: String,
            claudeVersion: String? = nil,
            pollInterval: Duration = .seconds(30),
            heartbeatInterval: Duration = .seconds(10 * 60)
        ) {
            self.capacity = capacity
            self.commanderVersion = commanderVersion
            self.claudeVersion = claudeVersion
            self.pollInterval = pollInterval
            self.heartbeatInterval = heartbeatInterval
        }
    }

    /// 生きている印に書く、この Mac の様子
    public struct MachineStatus: Sendable {
        public var diskFreeGB: Int
        public var load: Double
        public var selfCheck: SelfCheck

        public init(diskFreeGB: Int, load: Double, selfCheck: SelfCheck) {
            self.diskFreeGB = diskFreeGB
            self.load = load
            self.selfCheck = selfCheck
        }
    }

    /// 段階 2 で、この Mac が引き受けるジョブの種類
    static let handledKinds: Set<JobKind> = [.makeQuestions, .explain, .reviseQuestion, .checkReadiness, .reviseGoal]

    nonisolated let context: CommanderContext
    nonisolated let settings: Settings
    /// 人の意図の署名を確かめるもの（周ごとに、確かめた公開鍵の一覧から作り直す）
    nonisolated let verifier: @Sendable () async throws(CommanderError) -> IntentVerifier
    nonisolated let client: ClaudeClient
    nonisolated let workspace: any RepositoryWorkspace
    nonisolated let status: @Sendable () async -> MachineStatus
    /// 進行を止めているものを知らせるもの。APNs の設定が無ければ nil（知らせない）
    nonisolated let notifier: Notifier?
    nonisolated let log: @Sendable (String) -> Void
    nonisolated let sleeper: any Sleeper
    /// Discussion の写し。nil なら写さない
    nonisolated let mirror: DiscussionMirror?

    private var inFlight: [ULID: Task<Void, Never>] = [:]
    private var lastBeat: Date?

    public init(
        context: CommanderContext,
        settings: Settings,
        verifier: @escaping @Sendable () async throws(CommanderError) -> IntentVerifier,
        client: ClaudeClient,
        workspace: any RepositoryWorkspace,
        status: @escaping @Sendable () async -> MachineStatus,
        notifier: Notifier? = nil,
        log: @escaping @Sendable (String) -> Void,
        sleeper: any Sleeper = TaskSleeper(),
        mirror: DiscussionMirror? = nil
    ) {
        self.context = context
        self.settings = settings
        self.verifier = verifier
        self.client = client
        self.workspace = workspace
        self.status = status
        self.notifier = notifier
        self.log = log
        self.sleeper = sleeper
        self.mirror = mirror
    }

    /// 止められるまで回す。1 周で失敗しても、次の周でやり直す
    public func run() async {
        while !Task.isCancelled {
            do {
                _ = try await cycle()
            } catch {
                log("1 周を終えられなかった（\(error)）。次の周でやり直す")
            }
            do {
                try await sleeper.sleep(for: settings.pollInterval)
            } catch {
                break
            }
        }
    }

    /// 1 周。引き受けて動かし始めたジョブを返す
    @discardableResult
    public func cycle() async throws(CommanderError) -> [JobFile] {
        try await beatIfDue()
        let verifier = try await verifier()
        let intake = IntentIntake(context: context, verifier: verifier, handlers: Self.handlers)
        for outcome in try await intake.processPending() {
            log("人の意図: \(outcome)")
        }
        let swept = try await JobSweep(context: context).sweepAll()
        for job in swept.changed {
            log("ジョブ \(job.kind.rawValue) \(job.id) を \(job.state.rawValue) にした")
        }
        let picked = pick(from: swept.jobs)
        let worker = worker(verifier)
        for job in picked {
            start(job, with: worker)
        }
        await notify(swept, trusted: Set(verifier.publicKeys.keys))
        // 写しは表示のためだけのもの。人の意図とジョブを先に進め、写しの失敗は写しの中で扱う（次の周でやり直す）
        await mirror?.syncAll(verifier: verifier)
        return picked
    }

    /// ジョブを動かすワーカー。人の意図の処理と同じ `context`（同じ排他）で結果を書くよう、ループの中で作る
    nonisolated func worker(_ verifier: IntentVerifier) -> JobWorker {
        JobWorker(
            runner: ClaudeJobRunner(context: context, client: client, workspace: workspace, verifier: verifier),
            recorder: AttemptRecorder(files: context.files, mac: context.mac, now: context.now),
            now: context.now
        )
    }

    /// 動かしているジョブが終わるまで待つ
    public func waitForJobs() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    static let handlers: [String: any IntentHandler] = [
        "request": RequestHandler(),
        "answer": AnswerHandler(),
        "startEpic": StartEpicHandler(),
        "reviseGoal": ReviseGoalHandler(),
        "decideSplit": DecideSplitHandler(),
        "abandonEpic": AbandonEpicHandler(),
        "addRepository": AddRepositoryHandler(),
        "retry": RetryJobHandler(),
        "giveUp": GiveUpJobHandler()
    ]

    // MARK: - 引き受け

    /// 引き受けるジョブ。動かしているのに司令塔がまだ試行を読んでいない（`assigned` のままの）ジョブは選ばず、そのぶん空きを減らす
    private func pick(from jobs: [JobFile]) -> [JobFile] {
        let pending = jobs.filter { inFlight[$0.id] != nil && $0.state != .running }
        var capacity = settings.capacity
        capacity.claude = max(0, capacity.claude - pending.filter(\.needs.claude).count)
        capacity.build = max(0, capacity.build - pending.filter(\.needs.build).count)
        // 引き受けない種類の assigned のジョブは、空きを取られないよう候補から外す（running・succeeded は空きと依存の判断に要るので残す）
        let candidates = jobs.filter { job in
            job.state != .assigned || (Self.handledKinds.contains(job.kind) && inFlight[job.id] == nil)
        }
        return JobPicker.pick(from: candidates, for: context.mac, capacity: capacity, now: context.now())
    }

    private func start(_ job: JobFile, with worker: JobWorker) {
        let log = log
        inFlight[job.id] = Task { [weak self] in
            do {
                if let attempt = try await worker.perform(job) {
                    log("ジョブ \(job.kind.rawValue) \(job.id) の試行 #\(attempt.number): \(attempt.outcome.rawValue)")
                }
            } catch {
                log("ジョブ \(job.kind.rawValue) \(job.id) を終えられなかった（\(error)）")
            }
            await self?.finished(job.id)
        }
    }

    private func finished(_ id: ULID) {
        inFlight[id] = nil
    }

    // MARK: - 通知

    /// 進行を止めているものを知らせる。知らせられなくても、ジョブの引き受けは止めない
    private func notify(_ swept: JobSweep.Swept, trusted: Set<KeyID>) async {
        guard let notifier else { return }
        do {
            for notice in try await notifier.notify(epics: swept.epics, jobs: swept.jobs, trusted: trusted) {
                log("通知した: \(notice.title)（\(notice.body.replacingOccurrences(of: "\n", with: "・"))）")
            }
        } catch {
            log("通知を終えられなかった（\(error)）。次の周でやり直す")
        }
    }

    // MARK: - 生きている印

    private func beatIfDue() async throws(CommanderError) {
        let now = context.now()
        if let lastBeat, now.timeIntervalSince(lastBeat) < TimeInterval(settings.heartbeatInterval.components.seconds) { return }
        let machine = await status()
        let time = Timestamp(now)
        let commander = CommanderFile(
            mac: context.mac,
            seenAt: time,
            versions: .init(commander: settings.commanderVersion, claude: settings.claudeVersion),
            selfCheck: machine.selfCheck
        )
        let mac = MacFile(
            mac: context.mac,
            kind: .alwaysOn,
            seenAt: time,
            versions: .init(worker: settings.commanderVersion, claude: settings.claudeVersion),
            diskFreeGB: machine.diskFreeGB,
            load: machine.load,
            capacity: settings.capacity,
            selfCheck: machine.selfCheck
        )
        try await put(commander, at: StatePath.commander, message: "司令塔の生きている印")
        try await put(mac, at: StatePath.mac(context.mac), message: "\(context.mac) の生きている印")
        lastBeat = now
        // しばらく使っていないリポジトリの写しを片付ける
        await workspace.tidy()
    }

    /// 無ければ作り、あれば置き換える
    private func put<File: StateFile>(_ file: File, at path: String, message: String) async throws(CommanderError) {
        do {
            if try await context.files.read(File.self, at: path) == nil {
                try await context.files.create(file, at: path, message: message)
            } else {
                try await context.files.update(File.self, at: path, message: message) {
                    $0 = file
                    return true
                }
            }
        } catch .alreadyExists {
            throw .changedWhileProcessing(path)
        } catch {
            throw .files(error)
        }
    }
}
