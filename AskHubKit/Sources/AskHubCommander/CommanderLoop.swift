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

    /// この Mac が Claude に頼むジョブの種類（段階 2）
    static let claudeKinds: Set<JobKind> = [.makeQuestions, .explain, .reviseQuestion, .checkReadiness, .reviseGoal]

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
    /// epic の作業場所。この Mac が開始のときに選ばれたら、作業場所の用意（`prepareWorkspace`）も引き受ける。nil なら引き受けない
    nonisolated let epicWorkspace: (any EpicWorkspace)?
    /// タスクのジョブ（`implementTask`・`reviewTask`・`fixTask`）を動かすもの（`MachineRuntime.taskRunners`）。
    /// この Mac が開始のときに選ばれた epic の、自分宛てのものだけを引き受ける
    nonisolated let taskRunners: [JobKind: any JobRunning]

    /// 自分宛てのジョブを、同時の上限の中で並んで動かす
    nonisolated let slots: JobSlots
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
        mirror: DiscussionMirror? = nil,
        epicWorkspace: (any EpicWorkspace)? = nil,
        taskRunners: [JobKind: any JobRunning] = [:]
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
        self.epicWorkspace = epicWorkspace
        self.taskRunners = taskRunners
        let kinds = Self.claudeKinds.union(epicWorkspace == nil ? [] : [.prepareWorkspace]).union(taskRunners.keys)
        slots = JobSlots(mac: context.mac, capacity: settings.capacity, kinds: kinds, log: log)
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
        let picked = await slots.fill(from: swept.jobs, now: context.now(), with: worker(verifier))
        await notify(swept, trusted: Set(verifier.publicKeys.keys))
        // 写しは表示のためだけのもの。人の意図とジョブを先に進め、写しの失敗は写しの中で扱う（次の周でやり直す）
        await mirror?.syncAll(verifier: verifier)
        return picked
    }

    /// ジョブを動かすワーカー。人の意図の処理と同じ `context`（同じ排他）で結果を書くよう、ループの中で作る
    nonisolated func worker(_ verifier: IntentVerifier) -> JobWorker {
        let claude = ClaudeJobRunner(context: context, client: client, workspace: workspace, verifier: verifier)
        var runners: [JobKind: any JobRunning] = Dictionary(uniqueKeysWithValues: Self.claudeKinds.map { ($0, claude) })
        if let epicWorkspace { runners[.prepareWorkspace] = PrepareWorkspaceRunner(context: context, workspace: epicWorkspace) }
        runners.merge(taskRunners) { current, _ in current }
        return JobWorker(
            runner: JobDispatcher(runners),
            recorder: AttemptRecorder(files: context.files, mac: context.mac, now: context.now),
            now: context.now
        )
    }

    /// 動かしているジョブが終わるまで待つ
    public func waitForJobs() async {
        await slots.waitForJobs()
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
        let versions = MacFile.Versions(worker: settings.commanderVersion, claude: settings.claudeVersion)
        let mac = machine.macFile(mac: context.mac, kind: .alwaysOn, at: time, versions: versions, capacity: settings.capacity)
        try await context.put(commander, at: StatePath.commander, message: "司令塔の生きている印")
        try await context.put(mac, at: StatePath.mac(context.mac), message: "\(context.mac) の生きている印")
        lastBeat = now
        // しばらく使っていないリポジトリの写しを片付ける
        await workspace.tidy()
    }
}
