import AskHubProtocol
import Foundation

// MARK: - 開始した後の段取り

extension StateSnapshotBuilder {
    /// 開始した後の段取り。作業場所の用意 → タスクごと（実装 → 子 PR のチェックとレビュー → 直し → マージ）
    struct Progress {
        var workspace: Epic.Workspace?
        var tasks: [EpicTask]
        /// 機械がいましている段取り（Mac・試行・最後に動いた時刻つき）
        var activities: [EpicActivity] = []
        var history: [Epic.HistoryEntry] = []
    }

    /// 段取りに出すジョブの種類
    static let stepKinds: Set<JobKind> = [.prepareWorkspace, .implementTask, .reviewTask, .fixTask]
    /// 機械が受け持っている（人の対応を待たず、終わってもいない）ジョブの状態
    static let activeJobStates: Set<JobState> = [.queued, .assigned, .running, .paused]

    func progress(of documents: StateDocuments.EpicDocuments) -> Progress {
        let goalTasks = documents.goal?.tasks ?? []
        let jobs = documents.jobs.filter { Self.stepKinds.contains($0.kind) && $0.state != .canceled }
        var progress = Progress(
            workspace: workspace(of: documents.epic, jobs: jobs),
            tasks: goalTasks.enumerated().map { offset, task in
                EpicTask(id: task.id, number: offset + 1, title: task.title, state: state(of: task, jobs: jobs))
            }
        )
        for job in jobs where Self.activeJobStates.contains(job.state) {
            if let activity = activity(of: job, jobs: jobs, attempt: documents.attempts[job.id]?.last) {
                progress.activities.append(activity)
            }
        }
        // タスクがすべて終わった後の段取り（最終 PR）は、まだ司令塔が作らない
        if documents.epic.stage == .running, !goalTasks.isEmpty, goalTasks.allSatisfy({ $0.state == .done }), progress.activities.isEmpty {
            let finishedAt = jobs.map(\.updatedAt.date).max() ?? documents.epic.updatedAt.date
            progress.activities.append(EpicActivity(kind: .tasksFinished, since: finishedAt))
        }
        progress.history = stepHistory(of: documents.epic, tasks: progress.tasks, jobs: jobs)
        return progress
    }

    // MARK: 作業場所とタスク

    /// 作業場所の用意。開始する前（Mac を選んでいない）は出さない
    private func workspace(of epic: EpicFile, jobs: [JobFile]) -> Epic.Workspace? {
        if let branch = epic.branch {
            return .ready(branch: branch)
        }
        guard epic.mac != nil else {
            return nil
        }
        // 司令塔はジョブを作ってから epic を始めるので、始めた epic には作業場所の用意のジョブがある
        guard let job = Self.latest(jobs.filter { $0.kind == .prepareWorkspace }) else {
            return .pending
        }
        switch job.state {
        case .succeeded: return .ready(branch: nil)
        case .waitingHuman, .failed: return .failed
        case .queued, .assigned, .running, .paused, .canceled: return .preparing
        }
    }

    /// タスクの状態。進めているタスクは、そのタスクの最後のジョブから段階を決める
    private func state(of task: GoalFile.Task, jobs: [JobFile]) -> EpicTask.State {
        let taskJobs = jobs.filter { $0.task == task.id }
        switch task.state {
        case .pending:
            return .pending

        case .locked:
            return .locked(reason: "人がする作業を待っています")

        case .done:
            // マージしたのは、最後のレビュー
            return .done(pullRequest: Self.latest(taskJobs.filter { $0.kind == .reviewTask })?.pullRequest)

        case .running:
            guard let job = Self.latest(taskJobs) else {
                return .inProgress(nil)
            }
            if [.waitingHuman, .failed].contains(job.state) {
                return .failed
            }
            return .inProgress(phase(of: job, jobs: taskJobs, finished: job.state == .succeeded))
        }
    }

    /// ジョブが表すタスクの段階。終わったジョブなら、司令塔が次のジョブを作るまでの段階（実装の次はレビュー、直しの次もレビュー）
    private func phase(of job: JobFile, jobs: [JobFile], finished: Bool = false) -> EpicTask.Phase? {
        switch job.kind {
        case .implementTask:
            return finished ? .reviewing(pullRequest: nil) : .implementing

        case .reviewTask:
            return .reviewing(pullRequest: job.pullRequest)

        case .fixTask:
            guard !finished else {
                return .reviewing(pullRequest: job.pullRequest)
            }
            let input = job.input(as: FixTaskInput.self)
            let reason: EpicTask.FixReason? = input.map { $0.reason == .ci ? .checks : .review }
            // 何回目かは、同じタスクの直しのうち、これまでに作ったものの数（司令塔が 4 回目から人に渡すのと同じ数え方）
            let round = jobs.filter { $0.kind == .fixTask && ($0.createdAt, $0.id.rawValue) <= (job.createdAt, job.id.rawValue) }.count
            return .fixing(pullRequest: job.pullRequest, round: round, reason: reason)

        default:
            return nil
        }
    }

    /// 最後のジョブ。司令塔は次のジョブを前のジョブに `dependsOn` でつなぐので、ほかのジョブがつながっていないもの（同じなら新しいもの）
    static func latest(_ jobs: [JobFile]) -> JobFile? {
        let preceding = Set(jobs.flatMap(\.dependsOn))
        let leaves = jobs.filter { !preceding.contains($0.id) }
        return (leaves.isEmpty ? jobs : leaves).max { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }
    }

    // MARK: 機械がしていること

    private func activity(of job: JobFile, jobs: [JobFile], attempt: AttemptFile?) -> EpicActivity? {
        let step: WorkStep
        if job.kind == .prepareWorkspace {
            step = .prepareWorkspace
        } else {
            guard let task = job.task, let phase = phase(of: job, jobs: jobs.filter { $0.task == task }) else {
                return nil
            }
            step = .task(task, phase)
        }
        // 実行中の試行は、司令塔が当てた番号（`attempts`）のもの
        let running = attempt.flatMap { $0.number == job.attempts && $0.outcome == .running ? $0 : nil }
        let macID = running?.mac.rawValue ?? job.assignedMac?.rawValue
        let worker = macID.map { EpicActivity.Worker(macID: $0, heartbeatAt: running?.heartbeatAt.date) }
        switch job.state {
        case .running:
            let since = running?.startedAt.date ?? job.updatedAt.date
            return EpicActivity(kind: .step(step, .running(attempt: max(job.attempts, 1))), since: since, worker: worker)

        case .paused:
            guard let macID else {
                return nil
            }
            return EpicActivity(kind: .paused(macID: macID, since: job.updatedAt.date), since: job.updatedAt.date, worker: worker)

        default:
            if let retryAt = job.nextRunAt?.date, retryAt > now {
                return EpicActivity(kind: .step(step, .retrying(at: retryAt)), since: job.updatedAt.date, worker: worker)
            }
            return EpicActivity(kind: .step(step, .waitingForMac), since: job.updatedAt.date, worker: worker)
        }
    }

    // MARK: 履歴

    private func stepHistory(of epic: EpicFile, tasks: [EpicTask], jobs: [JobFile]) -> [Epic.HistoryEntry] {
        var entries: [Epic.HistoryEntry] = []
        let preparations = jobs.filter { $0.kind == .prepareWorkspace }
        if let first = preparations.min(by: { $0.createdAt < $1.createdAt }) {
            let mac = first.assignedMac?.rawValue ?? epic.mac?.rawValue ?? "Mac"
            entries.append(Epic.HistoryEntry(date: first.createdAt.date, text: "\(mac) で開始しました"))
        }
        if let branch = epic.branch, let prepared = preparations.first(where: { $0.state == .succeeded }) {
            entries.append(Epic.HistoryEntry(date: prepared.updatedAt.date, text: "作業ブランチ \(branch) を作りました"))
        }
        for task in tasks {
            guard case .done(let pullRequest) = task.state,
                  let merged = Self.latest(jobs.filter { $0.task == task.id && $0.kind == .reviewTask }) else {
                continue
            }
            let number = pullRequest.map { "（#\($0)）" } ?? ""
            entries.append(Epic.HistoryEntry(date: merged.updatedAt.date, text: "タスク \(task.number) をマージしました\(number)"))
        }
        return entries
    }

    // MARK: Mac

    /// その Mac で動いているジョブ（Mac の画面に出す）
    func runningJobs(on mac: MacName) -> [Mac.Job] {
        documents.epics.flatMap { epic in
            epic.jobs.compactMap { job -> Mac.Job? in
                let attempt = epic.attempts[job.id]?.last { $0.number == job.attempts }
                guard job.state == .running, (attempt?.mac ?? job.assignedMac) == mac else {
                    return nil
                }
                let title = "\(epic.epic.title): \(subject(of: job))"
                let startedAt = (attempt?.startedAt ?? job.updatedAt).date
                return Mac.Job(id: job.id.rawValue, title: title, epicID: epic.epic.id.rawValue, startedAt: startedAt)
            }
        }
        .sorted { $0.startedAt < $1.startedAt }
    }
}

extension JobFile {
    /// 子 PR を対象にするジョブ（レビュー・直し）の PR の番号
    var pullRequest: Int? {
        guard case .integer(let number)? = input?["pullRequest"] else {
            return nil
        }
        return Int(exactly: number)
    }
}
