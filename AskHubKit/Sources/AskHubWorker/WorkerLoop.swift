import AskHubCommander
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// ワーカー（`askhub-worker run`）の常駐のループ（`docs/renewal/architecture.md` の「ワーカーの中身」）。
///
/// 1 周ごとに、この Mac が受け持つ epic（開始のときに人が選んだ epic）のジョブを読み、自分宛ての `assigned` のジョブを、
/// 同時の上限の中で引き受けて並んで動かす（元になった人の意図の署名を確かめてから実行する）。生きている印（`macs/<mac>.json`）は、
/// 決めた間隔で書く。人の意図の処理とジョブの状態の更新はしない（司令塔の仕事）
public actor WorkerLoop {
    public struct Settings: Sendable {
        /// この Mac の種類（常駐できるか・できないか）
        public var kind: MacKind
        /// この Mac で同時に動かす数
        public var capacity: MacFile.Capacity
        public var workerVersion: String
        public var claudeVersion: String?
        /// 1 周の間隔（ジョブは ETag つきで読むので、変わっていなければ上限に数えられない）
        public var pollInterval: Duration
        /// 生きている印を書く間隔
        public var heartbeatInterval: Duration

        public init(
            kind: MacKind,
            capacity: MacFile.Capacity,
            workerVersion: String,
            claudeVersion: String? = nil,
            pollInterval: Duration = .seconds(60),
            heartbeatInterval: Duration = .seconds(10 * 60)
        ) {
            self.kind = kind
            self.capacity = capacity
            self.workerVersion = workerVersion
            self.claudeVersion = claudeVersion
            self.pollInterval = pollInterval
            self.heartbeatInterval = heartbeatInterval
        }
    }

    nonisolated let context: CommanderContext
    nonisolated let settings: Settings
    /// 人の意図の署名を確かめるもの（周ごとに、確かめた公開鍵の一覧から作り直す）
    nonisolated let verifier: @Sendable () async throws(CommanderError) -> IntentVerifier
    /// ジョブの種類ごとに実行するもの。ここに無い種類は引き受けない
    nonisolated let runners: [JobKind: any JobRunning]
    nonisolated let status: @Sendable () async -> CommanderLoop.MachineStatus
    /// 生きている印を書いた後に、しばらく使っていない写しを片付ける
    nonisolated let tidy: @Sendable () async -> Void
    nonisolated let log: @Sendable (String) -> Void
    nonisolated let sleeper: any Sleeper
    nonisolated let slots: JobSlots

    private var lastBeat: Date?

    public init(
        context: CommanderContext,
        settings: Settings,
        verifier: @escaping @Sendable () async throws(CommanderError) -> IntentVerifier,
        runners: [JobKind: any JobRunning],
        status: @escaping @Sendable () async -> CommanderLoop.MachineStatus,
        tidy: @escaping @Sendable () async -> Void = {},
        log: @escaping @Sendable (String) -> Void,
        sleeper: any Sleeper = TaskSleeper()
    ) {
        self.context = context
        self.settings = settings
        self.verifier = verifier
        self.runners = runners
        self.status = status
        self.tidy = tidy
        self.log = log
        self.sleeper = sleeper
        slots = JobSlots(mac: context.mac, capacity: settings.capacity, kinds: Set(runners.keys), log: log)
    }

    /// 止められるまで回す。1 周で失敗しても、次の周でやり直す
    public func run() async {
        while !Task.isCancelled {
            do {
                try await cycle()
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
        let jobs = try await context.jobsOfEpics(on: context.mac)
        return await slots.fill(from: jobs, now: context.now(), with: worker(verifier))
    }

    /// 動かしているジョブが終わるまで待つ
    public func waitForJobs() async {
        await slots.waitForJobs()
    }

    /// ジョブを動かすもの。元になった人の意図の署名を確かめてから、種類ごとのものに渡す
    nonisolated func worker(_ verifier: IntentVerifier) -> JobWorker {
        JobWorker(
            runner: OriginCheckedRunner(context: context, verifier: verifier, runner: JobDispatcher(runners)),
            recorder: AttemptRecorder(files: context.files, mac: context.mac, now: context.now),
            now: context.now
        )
    }

    private func beatIfDue() async throws(CommanderError) {
        let now = context.now()
        if let lastBeat, now.timeIntervalSince(lastBeat) < TimeInterval(settings.heartbeatInterval.components.seconds) { return }
        let versions = MacFile.Versions(worker: settings.workerVersion, claude: settings.claudeVersion)
        let (machine, time) = (await status(), Timestamp(now))
        let mac = machine.macFile(mac: context.mac, kind: settings.kind, at: time, versions: versions, capacity: settings.capacity)
        try await context.put(mac, at: StatePath.mac(context.mac), message: "\(context.mac) の生きている印")
        lastBeat = now
        await tidy()
    }
}
