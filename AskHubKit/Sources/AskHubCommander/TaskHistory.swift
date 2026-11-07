import AskHubProtocol
import AskHubStateStore
import Foundation

/// epic のジョブと試行から、タスクの前の結果を探す（前のタスクの要約・直しに渡す会話の id と直すこと）。
///
/// ジョブの `dependsOn` には頼らず、タスク・種類・入力で探す（司令塔がどの順でジョブを作っても同じ結果になる）
struct TaskHistory {
    struct Entry {
        var job: JobFile
        var attempt: AttemptFile
    }

    var context: CommanderContext
    var repo: RepositoryFullName
    var epic: ULID

    /// 種類が `kinds` に入るジョブの、成功した試行（終わった順）。`task` が nil なら、すべてのタスクのもの
    func succeeded(_ kinds: Set<JobKind>, task: String?) async throws(TaskJobExit) -> [Entry] {
        do {
            let jobs = try await context.jobList(repo, epic: epic).jobs.filter { job in
                kinds.contains(job.kind) && (task == nil || job.task == task)
            }
            var entries: [Entry] = []
            for job in jobs {
                for attempt in try await attempts(of: job) where attempt.outcome == .succeeded {
                    entries.append(Entry(job: job, attempt: attempt))
                }
            }
            return entries.sorted { ($0.attempt.endedAt ?? $0.attempt.startedAt) < ($1.attempt.endedAt ?? $1.attempt.startedAt) }
        } catch {
            throw .state(error)
        }
    }

    /// ゴールで終わったタスク（今のタスクを除く）と、その実装の報告の要約
    func previousTasks(in goal: GoalFile, before current: String) async throws(TaskJobExit) -> [ImplementTaskJob.PreviousTask] {
        let finished = goal.tasks.filter { $0.state == .done && $0.id != current }
        guard !finished.isEmpty else { return [] }
        let implemented = try await succeeded([.implementTask], task: nil)
        return finished.map { task in
            let summary = implemented.last { $0.job.task == task.id && $0.attempt.outputs?.report != nil }?.attempt.outputs?.report?.summary
            return ImplementTaskJob.PreviousTask(id: task.id, title: task.title, summary: summary ?? "（要約なし）")
        }
    }

    /// 直すこと。同じタスクの子 PR のレビューのうち、同じ PR と head を見て、直す理由に合う判定を書いた成功の試行のもの
    func findings(for input: FixTaskInput, task: String) async throws(TaskJobExit) -> String? {
        let verdict: ReviewVerdict = input.reason == .ci ? .fixCI : .fixReview
        let reviewed = PullRequestInput(pullRequest: input.pullRequest, head: input.head)
        return try await succeeded([.reviewTask], task: task).last { entry in
            entry.job.input(as: PullRequestInput.self) == reviewed && entry.attempt.outputs?.verdict == verdict
        }?.attempt.outputs?.findings
    }

    /// 実装の会話。同じタスクの実装と直しの成功の試行のうち、最後に終わったもの（`--resume` で会話の id が変わっても続けられる）
    func conversation(of task: String) async throws(TaskJobExit) -> Conversation? {
        let last = try await succeeded([.implementTask, .fixTask], task: task).last { $0.attempt.claude?.session != nil }
        guard let last, let session = last.attempt.claude?.session else { return nil }
        return Conversation(session: session, mac: last.attempt.mac)
    }

    /// Claude の会話と、それを動かした Mac（会話はその Mac の Claude の設定フォルダにだけ残る）
    struct Conversation: Equatable {
        var session: String
        var mac: MacName
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
