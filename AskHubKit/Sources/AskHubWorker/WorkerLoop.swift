import AskHubCommander
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// ワーカー（`askhub-worker run`）の常駐のループ（`docs/renewal/architecture.md` の「ワーカーの中身」）。
///
/// 1 周ごとに、この Mac が受け持つ epic（開始のときに人が選んだ epic）のジョブを読み、自分宛ての `assigned` のジョブを、
/// 同時の上限の中で引き受けて並んで動かす（元になった人の意図の署名を確かめてから実行する）。生きている印（`macs/<mac>.json`）は、
/// 決めた間隔で書く。人の意図の処理とジョブの状態の更新はしない（司令塔の仕事）。
///
/// 周ごとに司令塔の生きている印（`commander.json`）の互換の番号と自分の番号を照らし合わせ、合わなければ新しいジョブを引き受けず、
/// 理由を生きている印に書く（動かしているジョブは手放さない。`docs/renewal/operations.md` の「版」）
public actor WorkerLoop {
    public struct Settings: Sendable {
        /// この Mac の種類（常駐できるか・できないか）
        public var kind: MacKind
        /// この Mac で同時に動かす数
        public var capacity: MacFile.Capacity
        public var workerVersion: String
        /// このワーカーの互換の番号。司令塔の番号と合わなければ、新しいジョブを引き受けない
        public var compatibility: Int
        /// 起動したときの `claude` の版。印を書くときに測れなかったら、これを書く
        public var claudeVersion: String?
        /// 1 周の間隔（ジョブは ETag つきで読むので、変わっていなければ上限に数えられない）
        public var pollInterval: Duration
        /// 生きている印を書く間隔
        public var heartbeatInterval: Duration

        public init(
            kind: MacKind,
            capacity: MacFile.Capacity,
            workerVersion: String,
            compatibility: Int = MachineCompatibility.current,
            claudeVersion: String? = nil,
            pollInterval: Duration = .seconds(60),
            heartbeatInterval: Duration = .seconds(10 * 60)
        ) {
            self.kind = kind
            self.capacity = capacity
            self.workerVersion = workerVersion
            self.compatibility = compatibility
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
    /// 新しいジョブを引き受けていない理由（司令塔と互換の番号が合わない）。引き受けているときは nil
    private var refusal: JobRefusal?

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
        await checkCompatibility()
        try await beatIfDue()
        // 動かしているジョブは、引き受けないと決めた後もそのまま終わらせて試行を書く
        guard refusal == nil else { return [] }
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
        let (machine, time) = (await status(), Timestamp(now))
        let versions = MacFile.Versions(
            worker: settings.workerVersion,
            compatibility: settings.compatibility,
            claude: machine.claudeVersion ?? settings.claudeVersion,
            xcode: machine.xcodeVersion
        )
        var mac = machine.macFile(mac: context.mac, kind: settings.kind, at: time, versions: versions, capacity: settings.capacity)
        mac.refusal = refusal
        try await context.put(mac, at: StatePath.mac(context.mac), message: "\(context.mac) の生きている印")
        lastBeat = now
        await tidy()
    }

    // MARK: - 互換の番号

    /// 司令塔の生きている印の互換の番号と照らし合わせる。引き受けるかどうかが変わったら、生きている印をすぐ書き直す（次の間隔を待たずにクライアントに出す）
    private func checkCompatibility() async {
        let refusal: JobRefusal?
        do throws(StateFileStore.Failure) {
            let commander = try await context.files.read(CommanderFile.self, at: StatePath.commander)?.file
            refusal = Self.refusal(commander: commander?.versions.compatibility, own: settings.compatibility)
        } catch .unreadable(_, let error) {
            // 知らない版・形の違う commander.json は、司令塔の決まりが変わったとみなす
            let message = "司令塔の生きている印（\(StatePath.commander)）を読めない（\(error)）。ワーカーを更新するまで新しいジョブを引き受けない"
            refusal = JobRefusal(reason: .incompatible, message: message)
        } catch {
            // GitHub に届かないなどで読めなかったときは、前の周の判断のままにする
            log("司令塔の生きている印を読めなかった（\(error)）。互換の番号は前の周の判断のままにする")
            return
        }
        guard refusal != self.refusal else { return }
        self.refusal = refusal
        lastBeat = nil
        log(refusal.map { "新しいジョブを引き受けない: \($0.message)" } ?? "司令塔と互換の番号が合うので、新しいジョブを引き受ける")
    }

    /// 司令塔と自分の互換の番号から、新しいジョブを引き受けない理由を決める。
    /// 番号を書かない司令塔（前の版）・司令塔の印が無いときは照らし合わせない
    static func refusal(commander: Int?, own: Int) -> JobRefusal? {
        guard let commander, commander != own else { return nil }
        let update = commander > own ? "ワーカー" : "司令塔"
        return JobRefusal(
            reason: .incompatible,
            message: "司令塔の互換の番号は \(commander)、このワーカーは \(own)。\(update)を更新するまで新しいジョブを引き受けない"
        )
    }
}
