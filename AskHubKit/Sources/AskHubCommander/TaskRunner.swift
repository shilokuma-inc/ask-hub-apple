import AskHubClaude
import AskHubProtocol
import Foundation

/// Claude にタスクを進めさせる作業場所
public struct TaskWorkspace: Sendable {
    public var repository: RepositoryFullName
    /// リポジトリの事実（`RepositoryFacts.extract`）
    public var facts: String
    /// epic の作業場所（worktree）。`--restricted` で、Claude が読み書きできるのはここと `additionalDirectories` だけ
    public var directory: URL
    public var additionalDirectories: [URL]

    public init(repository: RepositoryFullName, facts: String, directory: URL, additionalDirectories: [URL] = []) {
        self.repository = repository
        self.facts = facts
        self.directory = directory
        self.additionalDirectories = additionalDirectories
    }
}

/// 1 回の実行（1 つの `implementTask`・`fixTask`）の上限
public struct TaskRunLimits: Equatable, Sendable {
    /// ビルドとテストの往復の回数
    public var roundTrips: Int
    /// 1 回の Claude の呼び出しの時間
    public var callTimeout: Duration
    /// 実行の全体（Claude の呼び出しとビルドとテストの合計）の時間
    public var total: Duration

    public init(roundTrips: Int = 20, callTimeout: Duration = .seconds(30 * 60), total: Duration = .seconds(4 * 60 * 60)) {
        self.roundTrips = roundTrips
        self.callTimeout = callTimeout
        self.total = total
    }
}

/// 実行の記録。試行の `claude`（`session.attemptRecord`）と `outputs` に書く元
public struct TaskRun: Equatable, Sendable {
    /// Claude の会話（id・使われたモデル・費用・呼び出しの回数）。最初の呼び出しで失敗したときは nil。
    /// 費用は会話全体の累計なので、直しの実行（`fixTask`）では実装の分も含む
    public var session: ClaudeSession?
    /// ビルドとテストを流した回数
    public var roundTrips: Int

    public init(session: ClaudeSession? = nil, roundTrips: Int = 0) {
        self.session = session
        self.roundTrips = roundTrips
    }

    /// 1 回の `ClaudeClient.ask` の記録を足す。費用は会話全体の累計なので、足さずに新しい値を使う
    mutating func record(_ next: ClaudeSession?) {
        guard var next else { return }
        next.id = next.id ?? session?.id
        next.estimatedCostUsd = next.estimatedCostUsd ?? session?.estimatedCostUsd
        next.calls += session?.calls ?? 0
        session = next
    }
}

public enum TaskReply: Sendable {
    /// `done`・`needsQuestion`・`blocked` のどれかで終わった（`needsBuild` で返ることはない）
    case reported(TaskReport, TaskRun)
    case failed(AttemptFailure, TaskRun)
}

/// Claude にタスクを実装させ、ビルドとテストの往復を進める（`docs/renewal/flows.md` の「Claude にビルドとテストを頼ませる」）。
///
/// Claude が `needsBuild` を返したら、`builds` で流して結果を付け、同じ会話を再開する（`--resume`）。
/// 報告が決まりに合わないときは、`ClaudeClient` が同じ会話で直させる
public struct TaskRunner: Sendable {
    public var client: ClaudeClient
    public var builds: any BuildService
    public var model: String
    public var limits: TaskRunLimits
    public var now: @Sendable () -> Date

    public init(
        client: ClaudeClient,
        builds: any BuildService,
        model: String = TaskRules.model,
        limits: TaskRunLimits = TaskRunLimits(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.builds = builds
        self.model = model
        self.limits = limits
        self.now = now
    }

    /// 最後に流したビルドとテストの様子
    private struct BuildState {
        var failing: Bool
        /// 落ちたままなら、その種類と結果の要約
        var lastFailure: (kind: TaskReport.BuildKind, summary: String)?
    }

    public func run(_ job: some TaskJob, in workspace: TaskWorkspace) async -> TaskReply {
        let start = now()
        var request = request(for: job, in: workspace)
        var state = BuildState(failing: job.startsFailing)
        var run = TaskRun()
        while true {
            guard let left = remaining(since: start) else { return .failed(timedOut, run) }
            request.timeout = min(limits.callTimeout, left)
            let failing = state.failing
            let report: TaskReport
            switch await client.ask(request, as: TaskReport.self, now: now, check: { $0.problems(lastBuildFailed: failing) }) {
            case let .failed(failure, session):
                run.record(session)
                return .failed(failure, run)
            case let .answered(answer, session):
                run.record(session)
                report = answer
            }
            guard report.outcome == .needsBuild, let kind = report.buildKind else { return .reported(report, run) }
            let build = await build(kind, state: &state, run: &run, since: start)
            if case let .couldNotRun(failure) = build { return .failed(failure, run) }
            request.resume = run.session?.id
            request.prompt = Self.buildResultPrompt(kind: kind, report: build, used: run.roundTrips, limit: limits.roundTrips)
        }
    }

    /// 頼まれたビルドかテストを流す。続けられないとき（往復の使い切り・時間切れ・流せなかった）は `couldNotRun` で返す
    private func build(
        _ kind: TaskReport.BuildKind,
        state: inout BuildState,
        run: inout TaskRun,
        since start: Date
    ) async -> TaskBuildResult {
        guard run.roundTrips < limits.roundTrips else { return .couldNotRun(exhausted(state)) }
        guard run.session?.id != nil else {
            return .couldNotRun(AttemptFailure(failureClass: .unexpected, message: "Claude の会話の id が無く、ビルドの結果を渡せない"))
        }
        guard remaining(since: start) != nil else { return .couldNotRun(timedOut) }
        let report = await builds.run(kind)
        run.roundTrips += 1
        switch report {
        case .couldNotRun:
            break
        case .passed:
            state = BuildState(failing: false)
        case let .failed(summary):
            state = BuildState(failing: true, lastFailure: (kind, summary))
        }
        return report
    }

    private func request(for job: some TaskJob, in workspace: TaskWorkspace) -> ClaudeRequest {
        ClaudeRequest(
            prompt: job.prompt,
            systemPrompt: TaskRules.systemPrompt(repository: workspace.repository, facts: workspace.facts, roundTrips: limits.roundTrips),
            model: model,
            outputSchema: TaskReport.outputSchema,
            tools: TaskRules.tools,
            workingDirectory: workspace.directory,
            additionalDirectories: workspace.additionalDirectories,
            timeout: limits.callTimeout,
            resume: job.resume,
            sandboxed: true
        )
    }

    /// 全体の上限までの残り。使い切っていれば nil
    private func remaining(since start: Date) -> Duration? {
        let elapsed = Duration.milliseconds(Int64((now().timeIntervalSince(start) * 1_000).rounded()))
        let left = limits.total - elapsed
        return left > .zero ? left : nil
    }

    private var timedOut: AttemptFailure {
        AttemptFailure(failureClass: .timeout, message: "タスクの実行が上限（\(limits.total)）を超えた")
    }

    /// 往復を使い切っても、Claude がまだビルドを頼んだ。最後のビルドかテストが落ちたままなら、その失敗として返す
    private func exhausted(_ state: BuildState) -> AttemptFailure {
        let message = "ビルドとテストの往復の上限（\(limits.roundTrips) 回）を使い切った"
        guard let failure = state.lastFailure else { return AttemptFailure(failureClass: .unexpected, message: message) }
        let failureClass: FailureClass = failure.kind == .build ? .buildFailed : .testFailed
        return AttemptFailure(failureClass: failureClass, message: message, logExcerpt: UntrustedText.tail(failure.summary, limit: 2_000))
    }

    /// ビルドとテストの結果の要約に載せる長さの上限（文字数）。超えた分は前を省く（失敗の理由は後ろに出る）
    static let maximumBuildSummaryLength = 8_000

    static func buildResultPrompt(kind: TaskReport.BuildKind, report: TaskBuildResult, used: Int, limit: Int) -> String {
        let (passed, summary): (Bool, String) = switch report {
        case let .passed(text): (true, text)
        case let .failed(text): (false, text)
        // 流せなかったときは Claude に渡さない（`run` が試行の失敗にする）
        case let .couldNotRun(failure): (false, failure.message)
        }
        let next = switch (used < limit, passed) {
        case (true, true):
            "続けてください。タスクが終わっていれば done で、まだなら作業を続けて needsBuild で確かめてください。残りの往復は \(limit - used) 回です。"
        case (true, false):
            "落ちた原因を直し、needsBuild でもう一度確かめてください。残りの往復は \(limit - used) 回です。"
        case (false, _):
            "往復の上限を使い切ったので、もうビルドとテストは頼めません。done・needsQuestion・blocked のどれかで報告してください（落ちたまま done にはできません）。"
        }
        return """
        ワーカーが \(kind.rawValue) を流しました。結果は「\(passed ? "通った" : "落ちた")」です（往復 \(used) / \(limit) 回目）。

        \(UntrustedText.block("build-result", summary.isBlank ? "（出力なし）" : UntrustedText.tail(summary, limit: maximumBuildSummaryLength)))

        \(next)
        """
    }
}
