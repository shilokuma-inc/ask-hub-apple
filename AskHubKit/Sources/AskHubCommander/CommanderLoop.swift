import AskHubClaude
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 常時オンの Mac の司令塔とワーカーの常駐のループ（`docs/renewal/flows.md` の「司令塔の動き」）。
///
/// 1 周ごとに、人の意図を処理し終えてから、試行を読んでジョブの状態を決め、実装している epic のタスクと最終 PR を進めるジョブを作り（`TaskFlow`）、
/// 自分宛ての Claude のジョブを引き受けて並んで動かし、進行を止めているものを知らせる。最後に、状態を Discussion の写しと照らし合わせる（写しに失敗しても、周は止めない）。
/// 生きている印（`commander.json`・`macs/<mac>.json`）は、決めた間隔で書く。GitHub の REST の上限の残りは、それより短い間隔で見て、少なくなったら知らせる
public actor CommanderLoop {
    public struct Settings: Sendable {
        /// 1 周の間隔（`intents/` は ETag つきで読むので、変わっていなければ上限に数えられない）
        public var pollInterval: Duration
        /// 休む間に、新しい人の意図が届いたかを見る間隔。届いていたら休みを切り上げて次の周を始める
        public var intentCheckInterval: Duration
        /// 生きている印を書く間隔
        public var heartbeatInterval: Duration
        /// GitHub の REST の上限の残りを見る間隔（`/rate_limit` は上限に数えられない）。生きている印の間隔より短くし、使い切る前に気づく
        public var rateLimitInterval: Duration
        /// この Mac で同時に動かす数
        public var capacity: MacFile.Capacity
        public var commanderVersion: String
        /// 生きている印に書く互換の番号。ワーカーはこれと自分の番号を照らし合わせる
        public var compatibility: Int
        /// 起動したときの `claude` の版。印を書くときに測れなかったら、これを書く
        public var claudeVersion: String?

        public init(
            capacity: MacFile.Capacity,
            commanderVersion: String,
            compatibility: Int = MachineCompatibility.current,
            claudeVersion: String? = nil,
            pollInterval: Duration = .seconds(30),
            intentCheckInterval: Duration = .seconds(5),
            heartbeatInterval: Duration = .seconds(10 * 60),
            rateLimitInterval: Duration = .seconds(60)
        ) {
            self.capacity = capacity
            self.commanderVersion = commanderVersion
            self.compatibility = compatibility
            self.claudeVersion = claudeVersion
            self.pollInterval = pollInterval
            self.intentCheckInterval = intentCheckInterval
            self.heartbeatInterval = heartbeatInterval
            self.rateLimitInterval = rateLimitInterval
        }
    }

    /// 生きている印に書く、この Mac の様子
    public struct MachineStatus: Sendable {
        public var diskFreeGB: Int
        public var load: Double
        public var selfCheck: SelfCheck
        /// いま使っている `claude` の版。測れなければ nil
        public var claudeVersion: String?
        /// ビルドとテストに使う Xcode の版（`xcodebuild -version`）。測れなければ nil
        public var xcodeVersion: String?

        public init(diskFreeGB: Int, load: Double, selfCheck: SelfCheck, claudeVersion: String? = nil, xcodeVersion: String? = nil) {
            self.diskFreeGB = diskFreeGB
            self.load = load
            self.selfCheck = selfCheck
            self.claudeVersion = claudeVersion
            self.xcodeVersion = xcodeVersion
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
    /// GitHub の REST の上限の残りを読む（`MachineProbe.githubRateLimit`）。読めなければ nil
    nonisolated let rateLimit: @Sendable () async -> GitHubRateLimit?
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
    /// 生きている印を書いた後に、リポジトリの写しのほかに片付けるもの（終わった epic の残りもの。`FinishedEpicCleanUp`）
    nonisolated let tidy: @Sendable () async -> Void
    /// 対象のアプリのアイコンを状態リポジトリに置くもの。生きている印を書いた後に、周の外で確かめ始める。nil なら置かない
    nonisolated let appIcons: AppIconSync?
    /// App Store での配信を見つけ、リリースの後作業を進めるもの。生きている印を書いた後に、周の外で見回り始める。nil なら見回らない
    nonisolated let releases: ReleaseWatch?

    /// 自分宛てのジョブを、同時の上限の中で並んで動かす
    nonisolated let slots: JobSlots
    private var lastBeat: Date?
    /// 最後に GitHub の REST の上限の残りを見た時刻と、読んだ残り（通知に使う。読めなければ nil）
    private var lastRateLimitCheck: Date?
    private var latestRateLimit: GitHubRateLimit?
    /// 残りが少なくなって、生きている印をすぐ書き直した窓（戻る時刻）。同じ窓では書き直さない
    private var lowRateLimitWindow: Timestamp?
    /// ログに出したタスクの流れの知らせ（同じものを周ごとに出さない）
    private var reportedNotes: Set<String> = []
    /// 前の周の初めに見た、まだ処理していなかった意図（休みを切り上げるかを決めるのに使う）
    private var seenIntents: Set<PendingIntent> = []

    public init(
        context: CommanderContext,
        settings: Settings,
        verifier: @escaping @Sendable () async throws(CommanderError) -> IntentVerifier,
        client: ClaudeClient,
        workspace: any RepositoryWorkspace,
        status: @escaping @Sendable () async -> MachineStatus,
        rateLimit: @escaping @Sendable () async -> GitHubRateLimit? = { nil },
        notifier: Notifier? = nil,
        log: @escaping @Sendable (String) -> Void,
        sleeper: any Sleeper = TaskSleeper(),
        mirror: DiscussionMirror? = nil,
        epicWorkspace: (any EpicWorkspace)? = nil,
        taskRunners: [JobKind: any JobRunning] = [:],
        tidy: @escaping @Sendable () async -> Void = {},
        appIcons: AppIconSync? = nil,
        releases: ReleaseWatch? = nil
    ) {
        self.context = context
        self.settings = settings
        self.verifier = verifier
        self.client = client
        self.workspace = workspace
        self.status = status
        self.rateLimit = rateLimit
        self.notifier = notifier
        self.log = log
        self.sleeper = sleeper
        self.mirror = mirror
        self.epicWorkspace = epicWorkspace
        self.taskRunners = taskRunners
        self.tidy = tidy
        self.appIcons = appIcons
        self.releases = releases
        let kinds = Self.claudeKinds.union(epicWorkspace == nil ? [] : [.prepareWorkspace]).union(taskRunners.keys)
        slots = JobSlots(mac: context.mac, capacity: settings.capacity, kinds: kinds, log: log)
    }

    /// 止められるまで回す。1 周で失敗しても、次の周でやり直す
    public func run() async {
        while !Task.isCancelled {
            var failureWait: Duration?
            do {
                _ = try await cycle()
            } catch {
                failureWait = Self.wait(after: error, pollInterval: settings.pollInterval)
                log("1 周を終えられなかった（\(error)）。\(CycleTimer.seconds(failureWait ?? settings.pollInterval)) 秒休んでから、次の周でやり直す")
            }
            do {
                if let failureWait {
                    try await sleeper.sleep(for: failureWait)
                } else {
                    try await rest()
                }
            } catch {
                break
            }
        }
    }

    /// 周を終えられなかったときに休む時間。意図の一覧を見て休みを切り上げない（意図を受け付ける前に失敗すると、前の周で見た意図の記録が古いままで、
    /// 休まずに失敗をくり返し、GitHub の上限を食い尽くすため）。上限（GitHub・書き込みの予算）なら言われた時間（長すぎれば `maxFailureWait` まで）、
    /// ほかの失敗は 1 周の間隔
    static func wait(after error: CommanderError, pollInterval: Duration) -> Duration {
        guard let retryAfter = error.retryAfter else { return pollInterval }
        return min(max(retryAfter, pollInterval), maxFailureWait)
    }

    /// 上限で休むときの長さの上限（生きている印が古くなりすぎないように）
    static let maxFailureWait: Duration = .seconds(15 * 60)

    /// 次の周まで `pollInterval` 休む。休む間も `intentCheckInterval` ごとに意図の一覧を見て（ETag つきなので、変わっていなければ上限に数えられない）、
    /// 前の周で見ていない意図が届いていたら、休みを切り上げる（人の操作を早く受け付けるため。1 周の途中に届いた意図も、周が終わってすぐ受け付ける）。
    /// 前の周で見た意図（扱えずに残したもの・書けずに残したもの）では切り上げない（同じ意図で休まずに回り続けないように）
    func rest() async throws {
        var rested: Duration = .zero
        while rested < settings.pollInterval {
            if await hasNewIntents() { return }
            let step = min(settings.intentCheckInterval, settings.pollInterval - rested)
            try await sleeper.sleep(for: step)
            rested += step
        }
    }

    /// 前の周で見ていない意図があるか。読めないときは、無いものとして休み続ける
    func hasNewIntents() async -> Bool {
        guard let pending = try? await IntentIntake.pending(in: context) else { return false }
        return pending.contains { !seenIntents.contains($0) }
    }

    /// 1 周。引き受けて動かし始めたジョブを返す
    @discardableResult
    public func cycle() async throws(CommanderError) -> [JobFile] {
        var timer = CycleTimer()
        await checkRateLimitIfDue()
        try await beatIfDue()
        let verifier = try await verifier()
        timer.lap("生きている印と鍵")
        let intake = IntentIntake(context: context, verifier: verifier, handlers: Self.handlers)
        // 順に 1 つずつ処理し、状態リポジトリに書けなかったらそこで止める（`IntentIntake.processPending` と同じ。次の周で続きから）
        let pending = try await intake.pending()
        seenIntents = Set(pending)
        for intent in pending {
            log("人の意図: \(try await intake.process(intent))")
        }
        timer.lap("人の意図")
        var swept = try await JobSweep(context: context).sweepAll()
        timer.lap("ジョブの見回り")
        for job in swept.changed {
            log("ジョブ \(job.kind.rawValue) \(job.id) を \(job.state.rawValue) にした")
        }
        // 実装している・最終 PR の段取りの epic のジョブの結果から、タスクと最終 PR を進めるジョブを作る（作ったジョブは、この周で引き受けられる）
        let advanced = await TaskFlow(context: context).advance(epics: swept.epics, jobs: swept.jobs)
        for job in advanced.created {
            log("ジョブ \(job.kind.rawValue) \(job.id)\(job.task.map { "（タスク \($0)）" } ?? "")を作った")
        }
        // 進められない理由は、変わるまで周ごとに同じものが出るので、初めて出たときだけログに出す
        for note in advanced.notes where reportedNotes.insert(note).inserted {
            log(note)
        }
        swept.jobs += advanced.created.filter { created in !swept.jobs.contains { $0.id == created.id } }
        timer.lap("タスクの流れ")
        // 見直しのまま止まった質問（見直すジョブが無い）の見直しを頼み直す
        let restarted = await RevisionRestart(context: context).restart(epics: swept.epics, jobs: swept.jobs, reading: swept.reader)
        for job in restarted.created {
            log("見直しのまま止まった質問 \(job.input?["question"]?.stringValue ?? "?") の見直し \(job.id) を作り直した")
        }
        for note in restarted.notes where reportedNotes.insert(note).inserted {
            log(note)
        }
        swept.jobs += restarted.created.filter { created in !swept.jobs.contains { $0.id == created.id } }
        let picked = await slots.fill(from: swept.jobs, now: context.now(), with: worker(verifier))
        await notify(swept, trusted: Set(verifier.publicKeys.keys))
        timer.lap("引き受けと通知")
        // 写しは表示のためだけのもの。人の意図とジョブを先に進め、写しの失敗は写しの中で扱う（次の周でやり直す）
        await mirror?.syncAll(verifier: verifier)
        timer.lap("Discussion の写し")
        if let report = timer.report { log(report) }
        return picked
    }

    /// ジョブを動かすワーカー。人の意図の処理と同じ `context`（同じ排他）で結果を書くよう、ループの中で作る
    nonisolated func worker(_ verifier: IntentVerifier) -> JobWorker {
        let claude = ClaudeJobRunner(context: context, client: client, workspace: workspace, verifier: verifier)
        var runners: [JobKind: any JobRunning] = Dictionary(uniqueKeysWithValues: Self.claudeKinds.map { ($0, claude) })
        if let epicWorkspace { runners[.prepareWorkspace] = PrepareWorkspaceRunner(context: context, workspace: epicWorkspace) }
        // タスクのジョブは push や子 PR の作成・マージをするので、ワーカー（`WorkerLoop`）と同じく、元になった人の意図の署名を確かめてから動かす
        let checked = taskRunners.mapValues { OriginCheckedRunner(context: context, verifier: verifier, runner: $0) as any JobRunning }
        runners.merge(checked) { current, _ in current }
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
        "pauseEpic": PauseEpicHandler(),
        "resumeEpic": ResumeEpicHandler(),
        "handover": HandoverHandler(),
        "addRepository": AddRepositoryHandler(),
        "configureRepository": ConfigureRepositoryHandler(),
        "removeRepository": RemoveRepositoryHandler(),
        "retry": RetryJobHandler(),
        "giveUp": GiveUpJobHandler(),
        "decision": DecisionHandler(),
        "approveMerge": ApproveMergeHandler(),
        "instructFinal": InstructFinalHandler(),
        "humanTaskDone": HumanTaskDoneHandler(),
        "verify": VerifyHandler(),
        "publishGitHubRelease": PublishGitHubReleaseHandler()
    ]

    // MARK: - 通知

    /// 進行を止めているものを知らせる。知らせられなくても、ジョブの引き受けは止めない
    private func notify(_ swept: JobSweep.Swept, trusted: Set<KeyID>) async {
        guard let notifier else { return }
        do {
            let releaseBlockers = await releases?.blockers ?? []
            let notices = try await notifier.notify(
                epics: swept.epics, jobs: swept.jobs, trusted: trusted, rateLimit: latestRateLimit, releases: releaseBlockers
            )
            for notice in notices {
                log("通知した: \(notice.title)（\(notice.body.replacingOccurrences(of: "\n", with: "・"))）")
            }
        } catch {
            log("通知を終えられなかった（\(error)）。次の周でやり直す")
        }
    }

    // MARK: - GitHub の上限

    /// GitHub の REST の上限の残りを、決めた間隔で読む。少なくなったら、その窓で 1 回だけ生きている印をすぐ書き直す
    /// （クライアントが次の印を待たずに気づけるように）。知らせるのは `notify`（窓ごとに 1 回）
    private func checkRateLimitIfDue() async {
        let now = context.now()
        if let lastRateLimitCheck, now.timeIntervalSince(lastRateLimitCheck) < TimeInterval(settings.rateLimitInterval.components.seconds) {
            return
        }
        lastRateLimitCheck = now
        latestRateLimit = await rateLimit()
        guard let limit = latestRateLimit, limit.isLow(at: now), lowRateLimitWindow != limit.resetAt else { return }
        lowRateLimitWindow = limit.resetAt
        lastBeat = nil
        log("GitHub の REST の残りが \(limit.remaining) 回になった（\(limit.resetAt) に \(limit.limit) 回に戻る）。生きている印を書き直して知らせる")
    }

    // MARK: - 生きている印

    private func beatIfDue() async throws(CommanderError) {
        let now = context.now()
        if let lastBeat, now.timeIntervalSince(lastBeat) < TimeInterval(settings.heartbeatInterval.components.seconds) { return }
        let machine = await status()
        let time = Timestamp(now)
        let claude = machine.claudeVersion ?? settings.claudeVersion
        let commander = CommanderFile(
            mac: context.mac,
            seenAt: time,
            versions: .init(commander: settings.commanderVersion, compatibility: settings.compatibility, claude: claude),
            selfCheck: machine.selfCheck
        )
        // 常時オンの Mac のワーカーは司令塔と同じ実行ファイルなので、互換の番号はいつも合う
        let versions = MacFile.Versions(
            worker: settings.commanderVersion, compatibility: settings.compatibility, claude: claude, xcode: machine.xcodeVersion
        )
        let mac = machine.macFile(mac: context.mac, kind: .alwaysOn, at: time, versions: versions, capacity: settings.capacity)
        try await context.put(commander, at: StatePath.commander, message: "司令塔の生きている印")
        try await context.put(mac, at: StatePath.mac(context.mac), message: "\(context.mac) の生きている印")
        lastBeat = now
        // しばらく使っていないリポジトリの写しと、終わった epic の残りものを片付ける
        await workspace.tidy()
        await tidy()
        appIcons?.start()
        releases?.start()
    }
}
