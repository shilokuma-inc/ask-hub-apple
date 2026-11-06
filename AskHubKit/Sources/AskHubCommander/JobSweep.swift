import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 司令塔が、終わっていないジョブの試行を読み、ジョブの状態を決めて書く（`JobReconciler`。ジョブのファイルは司令塔だけが書く）
public struct JobSweep: Sendable {
    public var context: CommanderContext
    public var policy: FailurePolicy
    public var timing: JobTiming

    public init(context: CommanderContext, policy: FailurePolicy = FailurePolicy(), timing: JobTiming = JobTiming()) {
        self.context = context
        self.policy = policy
        self.timing = timing
    }

    /// 試行を読んで状態を決めるジョブ（人に渡したジョブも、後から成功が書かれれば成功にする）
    static let watchedStates: Set<JobState> = [.assigned, .running, .paused, .waitingHuman]

    /// 見直した結果
    public struct Swept: Sendable {
        /// 状態を変えたジョブ
        public var changed: [JobFile]
        /// 終わっていない epic のすべてのジョブ（見直した後の状態。ワーカーが引き受けるジョブを選ぶのに使う）
        public var jobs: [JobFile]
        /// 終わっていない epic（進行を止めているものを知らせるのに使う）
        public var epics: [EpicFile] = []
    }

    /// 対象のリポジトリの、終わっていない epic のジョブを見直す。状態を変えたジョブを返す
    public func sweep() async throws(CommanderError) -> [JobFile] {
        try await sweepAll().changed
    }

    /// 対象のリポジトリの、終わっていない epic のジョブを見直し、見直した後のジョブの一覧も返す
    public func sweepAll() async throws(CommanderError) -> Swept {
        var swept = Swept(changed: [], jobs: [])
        for repo in try await context.repositories() {
            // 終わっていない（マージ・やめた、でない）epic
            for epic in try await context.epics(of: repo, where: { ![.merged, .abandoned].contains($0.stage) }) {
                swept.epics.append(epic)
                // 読めないジョブは、中身が分からないので触らない（新しい司令塔が扱う）
                for job in try await context.jobList(repo, epic: epic.id).jobs {
                    guard Self.watchedStates.contains(job.state), let next = try await reconcile(job) else {
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

    /// 1 つのジョブの試行を読み、状態が変わるなら書く。読んだ後にほかで書き換わっていたら、書かずに次の周に回す
    func reconcile(_ job: JobFile) async throws(CommanderError) -> JobFile? {
        let attempts = try await attempts(of: job)
        let macName = attempts.max { $0.number < $1.number }?.mac ?? job.assignedMac
        var mac: MacFile?
        if let macName { mac = try await context.readable(MacFile.self, at: StatePath.mac(macName)) }
        let next = JobReconciler.reconcile(job, attempts: attempts, mac: mac, now: context.now(), policy: policy, timing: timing)
        guard next != job else { return nil }
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

    private func attempts(of job: JobFile) async throws(CommanderError) -> [AttemptFile] {
        let entries: [DirectoryEntry]
        do {
            entries = try await context.store.listAll(StatePath.attempts(job.repo, epic: job.epic, job: job.id)) ?? []
        } catch {
            throw .store(error)
        }
        var attempts: [AttemptFile] = []
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
            if let attempt = try await context.readable(AttemptFile.self, at: entry.path) { attempts.append(attempt) }
        }
        return attempts
    }
}
