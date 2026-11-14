import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 司令塔が、終わっていないジョブの試行を読み、ジョブの状態を決めて書く（`JobReconciler`。ジョブのファイルは司令塔だけが書く）。
///
/// 人の一時停止と引き継ぎ（`EpicHold`）も、ここで epic ごとに当てる。一時停止の間は引き受けられるジョブを止めたままにし、再開したら戻し、
/// 引き継いだら動いていないジョブを epic の今の Mac に付け替える（人の意図の処理は epic を書き換えるだけで、ジョブは同じ周のここで動かす）
public struct JobSweep: Sendable {
    public var context: CommanderContext
    public var policy: FailurePolicy
    public var timing: JobTiming
    /// この起動の始まり。これより前に印を書いた、この Mac（司令塔）の実行中の試行は、前の起動で残ったものなので、
    /// `JobSlots` が「Mac がオフライン」で閉じるまで決めない（閉じる前に時間切れと決めないように）
    public var leftoversBefore: Date?

    public init(
        context: CommanderContext,
        policy: FailurePolicy = FailurePolicy(),
        timing: JobTiming = JobTiming(),
        leftoversBefore: Date? = nil
    ) {
        self.context = context
        self.policy = policy
        self.timing = timing
        self.leftoversBefore = leftoversBefore
    }

    /// 試行を読んで状態を決めるジョブ（人に渡したジョブも、後から成功が書かれれば成功にする）
    static let watchedStates: Set<JobState> = [.assigned, .running, .paused, .waitingHuman]

    /// 見直した結果
    public struct Swept: Sendable {
        /// 状態を変えたジョブ
        public var changed: [JobFile]
        /// ジョブを見張る epic のすべてのジョブ（見直した後の状態。ワーカーが引き受けるジョブを選ぶのに使う）
        public var jobs: [JobFile]
        /// ジョブを見張る epic（終わっていない epic と、片付けが残るマージしてから間もない epic。進行を止めているものを知らせるのに使う）
        public var epics: [EpicFile] = []
        /// 見直したときに読んだ、周の初めの読むだけの写し（見直しのまま止まった質問を探すのに使う。`RevisionRestart`）
        var reader: CommanderContext?
    }

    /// 対象のリポジトリの、ジョブを見張る epic のジョブを見直す。状態を変えたジョブを返す
    public func sweep() async throws(CommanderError) -> [JobFile] {
        try await sweepAll().changed
    }

    /// 対象のリポジトリの、ジョブを見張る epic のジョブを見直し、見直した後のジョブの一覧も返す。
    ///
    /// epic・ジョブ・試行・Mac の印は、周の初めに作る読むだけの写しから読む（変わっていないものは取りに行かない）。
    /// 状態を変えるときは、元の置き場所で読み直し、写しで読んだときから変わっていなければ書く
    public func sweepAll() async throws(CommanderError) -> Swept {
        var swept = Swept(changed: [], jobs: [])
        let now = context.now()
        let reader = try await context.snapshot()
        swept.reader = reader
        for repo in try await reader.repositories() {
            // 終わっていない epic と、マージの後の片付けが残る epic（`EpicFile.watchesJobs(now:)`）
            for epic in try await reader.epics(of: repo, where: { $0.watchesJobs(now: now) }) {
                swept.epics.append(epic)
                // 読めないジョブは、中身が分からないので触らない（新しい司令塔が扱う）
                for job in try await reader.jobList(repo, epic: epic.id).jobs {
                    guard Self.watchedStates.contains(job.state),
                          let next = try await reconcile(job, in: epic, reading: reader) else {
                        swept.jobs.append(job)
                        continue
                    }
                    swept.changed.append(next)
                    swept.jobs.append(next)
                }
            }
        }
        return swept
    }

    /// 1 つのジョブの試行を読み、状態が変わるなら書く。読んだ後にほかで書き換わっていたら、書かずに次の周に回す。
    /// `epic` を渡すと、人の一時停止と引き継ぎ（`EpicHold`）も当てる。
    ///
    /// `reader`（周の初めの写し）を渡すと、試行と Mac の印をまず写しから読む。状態を変えると決めたら、書く前に元の置き場所で読み直して決め直す
    /// （写しを作った後に書かれた生きている印や結果を見落として、動いている試行を止まったとみなさないように）
    func reconcile(
        _ job: JobFile,
        in epic: EpicFile? = nil,
        reading reader: CommanderContext? = nil
    ) async throws(CommanderError) -> JobFile? {
        var next = try await decide(job, in: epic, reading: reader ?? context)
        guard next != job else { return nil }
        if reader != nil {
            next = try await decide(job, in: epic, reading: context)
            guard next != job else { return nil }
        }
        var written = false
        do {
            let path = StatePath.job(job.repo, epic: job.epic, job: job.id)
            try await context.files.update(JobFile.self, at: path, message: "ジョブ \(job.kind.rawValue) を \(next.state.rawValue) にする") {
                guard $0 == job else { return false }
                $0 = next
                written = true
                return true
            }
        } catch {
            throw .files(error)
        }
        return written ? next : nil
    }

    /// 試行と Mac の印を `reader` から読み、ジョブの次の状態を決める（変わらなければ `job` のまま）
    private func decide(_ job: JobFile, in epic: EpicFile?, reading reader: CommanderContext) async throws(CommanderError) -> JobFile {
        let attempts = try await Self.attempts(of: job, in: reader)
        let latest = attempts.max { $0.number < $1.number }
        if let leftoversBefore, let latest, latest.mac == context.mac, latest.outcome == .running,
           latest.heartbeatAt.date < leftoversBefore {
            return job
        }
        let macName = latest?.mac ?? job.assignedMac
        var mac: MacFile?
        if let macName { mac = try await reader.readable(MacFile.self, at: StatePath.mac(macName)) }
        let now = context.now()
        var next = JobReconciler.reconcile(job, attempts: attempts, mac: mac, now: now, policy: policy, timing: timing)
        if let epic {
            if let epicMac = epic.mac {
                next = EpicHold.realign(next, to: epicMac, commander: context.mac, attempts: attempts, now: now)
            }
            next = epic.pause == nil
                ? EpicHold.release(next, was: job, attempts: attempts, now: now)
                : EpicHold.hold(next, was: job, attempts: attempts, now: now)
        }
        return next
    }

    private static func attempts(of job: JobFile, in reader: CommanderContext) async throws(CommanderError) -> [AttemptFile] {
        let entries: [DirectoryEntry]
        do {
            entries = try await reader.store.listAll(StatePath.attempts(job.repo, epic: job.epic, job: job.id)) ?? []
        } catch {
            throw .store(error)
        }
        var attempts: [AttemptFile] = []
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
            if let attempt = try await reader.readable(AttemptFile.self, at: entry.path) { attempts.append(attempt) }
        }
        return attempts
    }
}
