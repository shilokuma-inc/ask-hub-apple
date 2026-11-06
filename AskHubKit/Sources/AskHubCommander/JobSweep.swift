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

    /// 対象のリポジトリの、終わっていない epic のジョブを見直す。状態を変えたジョブを返す
    public func sweep() async throws(CommanderError) -> [JobFile] {
        var changed: [JobFile] = []
        for repo in try await repositories() {
            for epic in try await openEpics(of: repo) {
                // 読めないジョブは、中身が分からないので触らない（新しい司令塔が扱う）
                for job in try await context.jobList(repo, epic: epic).jobs where Self.watchedStates.contains(job.state) {
                    if let next = try await reconcile(job) { changed.append(next) }
                }
            }
        }
        return changed
    }

    /// 1 つのジョブの試行を読み、状態が変わるなら書く。読んだ後にほかで書き換わっていたら、書かずに次の周に回す
    func reconcile(_ job: JobFile) async throws(CommanderError) -> JobFile? {
        let attempts = try await attempts(of: job)
        let macName = attempts.max { $0.number < $1.number }?.mac ?? job.assignedMac
        var mac: MacFile?
        if let macName { mac = try await readable(MacFile.self, at: StatePath.mac(macName)) }
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

    /// `repos/<owner>/<repo>/` の一覧
    private func repositories() async throws(CommanderError) -> [RepositoryFullName] {
        var repositories: [RepositoryFullName] = []
        for owner in try await directories(in: StatePath.repositories) {
            for name in try await directories(in: "\(StatePath.repositories)/\(owner)") {
                if let repo = RepositoryFullName(rawValue: "\(owner)/\(name)") { repositories.append(repo) }
            }
        }
        return repositories
    }

    /// 終わっていない（マージ・やめた、でない）epic。読めない epic は飛ばす
    private func openEpics(of repo: RepositoryFullName) async throws(CommanderError) -> [ULID] {
        var epics: [ULID] = []
        for name in try await directories(in: StatePath.epics(repo)) {
            guard let id = ULID(rawValue: name),
                  let epic = try await readable(EpicFile.self, at: StatePath.epic(repo, id)),
                  ![.merged, .abandoned].contains(epic.stage) else { continue }
            epics.append(id)
        }
        return epics
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
            if let attempt = try await readable(AttemptFile.self, at: entry.path) { attempts.append(attempt) }
        }
        return attempts
    }

    /// ディレクトリの直下のディレクトリの名前
    private func directories(in directory: String) async throws(CommanderError) -> [String] {
        do {
            return try await context.store.listAll(directory)?.filter { $0.kind == .directory }.map(\.name) ?? []
        } catch {
            throw .store(error)
        }
    }

    /// 読めない（知らない版など）ファイルは nil にして飛ばす
    private func readable<File: StateFile>(_ type: File.Type, at path: String) async throws(CommanderError) -> File? {
        do {
            return try await context.files.read(File.self, at: path)?.file
        } catch .unreadable {
            return nil
        } catch {
            throw .files(error)
        }
    }
}
