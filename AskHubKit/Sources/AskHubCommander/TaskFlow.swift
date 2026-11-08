import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 司令塔が、実装している（`running`）epic と最終 PR の段取りの（`finalizing`・`reviewing`）epic のジョブの結果を読み、
/// タスクと最終 PR を進めるジョブを作る（`docs/renewal/flows.md` の「タスクの流れ」「最終 PR までの段取り」）。
///
/// ジョブの状態を決めた後（`JobSweep`）に、epic ごとに、人の意図の処理と同じ排他の中で行う。
///
/// | 成功したジョブ | すること |
/// | --- | --- |
/// | 作業場所の用意 | 作業ブランチを `epic.json` に書き、最初のタスクの実装を作る |
/// | 実装・直し | 仮決めを `decisions.json` に足し、子 PR のレビューを作る |
/// | レビュー（マージした） | タスクを `done` にし、次のタスクの実装を作る。人がする作業も含めてすべて済んだら、最終 PR の段取りに進む（`TaskFlow+Final.swift`） |
/// | レビュー（直す判定） | 直しを作る。同じタスクの直しが上限を超えたら、動かさずに人の対応待ちで作る |
/// | 実装・直し（質問で終えた） | 質問を `questions.json` に足し、答えるまで次のジョブを作らない（`TaskFlow+Questions.swift`） |
///
/// 作るジョブは epic の Mac に割り当て、元のジョブを `dependsOn` に持たせる（どの結果から作ったかの目印。子の無い成功したジョブだけを読む）。
/// id は元のジョブ（と直しの回）から決めるので、途中で止まってやり直しても同じジョブを 2 つ作らない
public struct TaskFlow: Sendable {
    public var context: CommanderContext
    /// 直させる回数の上限（`maxFixRounds`。失敗の扱いと同じ）
    public var policy: FailurePolicy

    public init(context: CommanderContext, policy: FailurePolicy = FailurePolicy()) {
        self.context = context
        self.policy = policy
    }

    /// 進めた結果
    public struct Advanced: Sendable, Equatable {
        /// 作ったジョブ（同じ周で引き受けられるよう、ジョブの一覧に足す）
        public var created: [JobFile] = []
        /// ログに出すこと（進められない理由・人に渡したこと・すべて済んだこと）
        public var notes: [String] = []
    }

    /// タスクに結びつくジョブの種類
    static let taskKinds: Set<JobKind> = [.implementTask, .reviewTask, .fixTask]

    /// 進める epic の段階（実装・最終 PR の段取り・人の確認の待ち）
    static let stages: Set<EpicStage> = [.running, .finalizing, .reviewing]

    /// `epics` は終わっていない epic、`jobs` はそのジョブ（見直した後のもの）。1 つの epic で失敗しても、ほかの epic は進める。
    /// 人が一時停止した epic（`EpicFile.pause`）は、再開するまで進めない（次のジョブを作らない）
    public func advance(epics: [EpicFile], jobs: [JobFile]) async -> Advanced {
        var advanced = Advanced()
        for epic in epics.sorted(by: { $0.id < $1.id }) where Self.stages.contains(epic.stage) && epic.pause == nil {
            let own = jobs.filter { $0.repo == epic.repo && $0.epic == epic.id }
            do {
                let step = try await context.lock.withLock { () throws(CommanderError) -> Advanced in
                    try await advance(epic, jobs: own)
                }
                advanced.created += step.created
                advanced.notes += step.notes
            } catch {
                advanced.notes.append("epic \(epic.id) のタスクを進められなかった（\(error)）。次の周でやり直す")
            }
        }
        return advanced
    }

    /// 1 つの epic を進める。`context.lock` の中で呼ぶ
    func advance(_ seen: EpicFile, jobs: [JobFile]) async throws(CommanderError) -> Advanced {
        // 排他を待つ間に変わっていないかを読み直す。作業場所の用意が済むまでは、タスクに進まない
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(seen.repo, seen.id)), Self.stages.contains(epic.stage),
              epic.pause == nil, let prepare = jobs.first(where: { $0.kind == .prepareWorkspace && $0.state == .succeeded }) else {
            return Advanced()
        }
        guard let plan = Plan(context: context, epic: epic, prepare: prepare) else {
            return Advanced(notes: ["epic \(epic.id) は Mac か開始の人の意図が分からず、タスクのジョブを作れない"])
        }
        if epic.branch == nil {
            guard let branch = try await succeededOutputs(of: prepare)?.branch else {
                return Advanced(notes: ["epic \(epic.id) の作業場所の用意の結果に、作業ブランチが無い"])
            }
            try await writeBranch(branch, to: epic)
        }
        guard let goal = try await context.read(GoalFile.self, at: StatePath.goal(epic.repo, epic.id)) else {
            return Advanced(notes: ["epic \(epic.id) のゴールが無い"])
        }
        // 実装の途中の質問の答えを待つ間は、次のジョブを作らない（`TaskFlow+Questions.swift`）
        if let asked = try await questions(of: epic, jobs: jobs) { return asked }
        guard epic.stage == .running else { return try await advanceFinal(goal, plan: plan, jobs: jobs) }
        return try await advance(goal, plan: plan, jobs: jobs)
    }

    /// 動いているタスクの次の一手を決め、子 PR をマージしたら次のタスクを始める。すべて済んだら最終 PR の段取りに進む
    func advance(_ goal: GoalFile, plan: Plan, jobs: [JobFile]) async throws(CommanderError) -> Advanced {
        var goal = goal
        if let task = goal.tasks.first(where: { $0.state == .running }) {
            let step = try await step(task, plan: plan, jobs: jobs)
            guard step == .merged else { return advanced(by: step, task: task, epic: plan.epic) }
            goal = try await setState(.done, of: task.id, from: [.running], in: plan.epic)
        }
        // 最後のタスクを done にした後に止まっても、次の周でここから進む（人がする作業が残っていれば、終わるのを待つ）
        if goal.tasks.allSatisfy({ $0.state == .done }) { return try await startFinalAfterHumanTasks(goal, plan: plan, jobs: jobs) }
        guard let job = try await startNext(goal, plan: plan) else { return Advanced() }
        return Advanced(created: [job])
    }

    /// 次の一手を、作ったジョブとログに出すことにする
    func advanced(by step: Step, task: GoalFile.Task, epic: EpicFile) -> Advanced {
        switch step {
        case .waiting, .merged:
            return Advanced()
        case let .stuck(note):
            return Advanced(notes: [note])
        case let .created(job):
            guard job.state == .waitingHuman else { return Advanced(created: [job]) }
            let note = "epic \(epic.id) のタスク \(task.id) の直しが上限（\(policy.maxFixRounds) 回）を超えたので、人に渡した（\(job.id)）"
            return Advanced(created: [job], notes: [note])
        }
    }

    /// 動いているタスクの次の一手
    enum Step: Equatable {
        /// 動いているジョブを待つ（人の対応待ちを含む）
        case waiting
        case created(JobFile)
        /// 子 PR をマージした
        case merged
        /// 結果が欠けていて進められない（ログに出す）
        case stuck(String)
    }

    /// 動いているタスクの、まだ子の無い成功したジョブ（ふつうは 1 つ）の結果から、次のジョブを決める
    func step(_ task: GoalFile.Task, plan: Plan, jobs: [JobFile]) async throws(CommanderError) -> Step {
        let chain = jobs.filter { $0.task == task.id && Self.taskKinds.contains($0.kind) }
        // 実装のジョブを作ってから running にするので、ふつうは無いことはない（読めない・消されたときは、作り直さずに知らせる）
        guard chain.contains(where: { $0.kind == .implementTask }) else {
            return .stuck("epic \(plan.epic.id) のタスク \(task.id) は running なのに、実装のジョブが読めない")
        }
        let parents = Set(chain.flatMap(\.dependsOn))
        guard let tail = chain.filter({ $0.state == .succeeded && !parents.contains($0.id) }).min(by: { $0.id < $1.id }) else {
            return .waiting
        }
        switch tail.kind {
        case .reviewTask: return try await fix(after: tail, task: task, chain: chain, plan: plan)
        default: return try await review(after: tail, task: task, plan: plan)
        }
    }

    /// 実装・直しが成功した: 仮決めを足し、子 PR のレビュー（push した head を固定する）を作る
    func review(after job: JobFile, task: GoalFile.Task, plan: Plan) async throws(CommanderError) -> Step {
        let outputs = try await succeededOutputs(of: job)
        guard let pullRequest = outputs?.pullRequest ?? job.input(as: FixTaskInput.self)?.pullRequest, let head = outputs?.commit else {
            return .stuck("epic \(plan.epic.id) のタスク \(task.id) の \(job.kind.rawValue)（\(job.id)）の結果に、子 PR かコミットが無い")
        }
        try await addDecisions(outputs?.report?.decisions ?? [], task: task.id, pullRequest: pullRequest, epic: plan.epic)
        let input = PullRequestInput(pullRequest: pullRequest, head: head)
        let review = plan.job(.reviewTask, for: task.id, input: input, after: job, seed: "\(job.id)/\(head)")
        try await context.create(review)
        return .created(review)
    }

    /// レビューが成功した: マージしたなら次へ、直す判定なら直しを作る（同じタスクの直しが上限を超えたら、人の対応待ちで作る）
    func fix(after review: JobFile, task: GoalFile.Task, chain: [JobFile], plan: Plan) async throws(CommanderError) -> Step {
        guard let verdict = try await succeededOutputs(of: review)?.verdict, let seen = review.input(as: PullRequestInput.self) else {
            return .stuck("epic \(plan.epic.id) のタスク \(task.id) のレビュー（\(review.id)）の結果に、判定が無い")
        }
        let reason: FixTaskInput.Reason
        switch verdict {
        case .merged: return .merged
        case .fixCI: reason = .ci
        case .fixReview: reason = .review
        // 最終 PR のレビューの判定。子 PR のレビューには出ないので、壊れた結果として人に渡す
        case .ready, .fixConflict:
            let what = "epic \(plan.epic.id) のタスク \(task.id) の子 PR のレビュー（\(review.id)）"
            return .stuck("\(what)に、最終 PR の判定（\(verdict.rawValue)）がある")
        }
        // 実装の途中の質問の答えで再開した直しは、同じ直しの続きなので数えない
        let round = chain.filter { $0.kind == .fixTask && $0.state != .canceled && !$0.resumesQuestion }.count + 1
        let input = FixTaskInput(pullRequest: seen.pullRequest, head: seen.head, reason: reason)
        var fix = plan.job(.fixTask, for: task.id, input: input, after: review, seed: "\(review.id)/\(round)")
        // 失敗の扱いと同じく、上限を超えたら動かさずに人に渡す（人が「やり直す」を送れば、もう 1 回直す）
        if round > policy.maxFixRounds { fix.state = .waitingHuman }
        try await context.create(fix)
        return .created(fix)
    }

    /// 次のタスク（`dependsOn` のタスクと人がする作業がすべて済んだ pending のもの。ゴールの並びの順）の実装を作り、running にする
    func startNext(_ goal: GoalFile, plan: Plan) async throws(CommanderError) -> JobFile? {
        let done = Set(goal.tasks.filter { $0.state == .done }.map(\.id) + goal.humanTasks.filter { $0.state == .done }.map(\.id))
        guard let next = goal.tasks.first(where: { $0.state == .pending && Set($0.dependsOn).isSubset(of: done) }) else { return nil }
        // ジョブを先に作る（running にする前に止まっても、次の周で同じ id のジョブを作ろうとするだけ）。
        // タスクは 1 回だけ実装するので、id はタスクから決める
        let job = plan.job(.implementTask, for: next.id, input: nil, after: plan.prepare, seed: next.id)
        try await context.create(job)
        try await setState(.running, of: next.id, from: [.pending], in: plan.epic)
        return job
    }
}

extension TaskFlow {
    /// タスクのジョブを作るのに使うもの
    struct Plan {
        var context: CommanderContext
        var epic: EpicFile
        /// 開始のときに人が選んだ Mac。タスクのジョブはすべてここで動かす
        var mac: MacName
        /// 開始の人の意図（ワーカーが署名を確かめる）。作業場所の用意のジョブと同じ
        var origin: IntentReference
        var prepare: JobFile

        init?(context: CommanderContext, epic: EpicFile, prepare: JobFile) {
            guard let mac = epic.mac, let origin = prepare.origin else { return nil }
            self.context = context
            self.epic = epic
            self.mac = mac
            self.origin = origin
            self.prepare = prepare
        }

        /// `parent` の結果から作るジョブ。id は開始の人の意図と `seed` から決める
        func job(_ kind: JobKind, for task: String, input: (any JobInput)?, after parent: JobFile, seed: String) -> JobFile {
            // レビューは Claude が読むだけで、ビルドは流さない（チェックは CI が流す）
            let needs = JobFile.Needs(claude: true, build: kind != .reviewTask)
            let spec = JobSpec(kind: kind, mac: mac, needs: needs, input: input?.jobInput ?? [:], dependsOn: [parent.id])
            var job = context.job(spec, for: epic, origin: origin, seed: seed)
            job.task = task
            return job
        }
    }
}
