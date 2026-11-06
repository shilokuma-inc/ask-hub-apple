import AskHubClaude
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 常時オンの Mac のワーカーとして、自分宛ての Claude のジョブを 1 つ引き受けて実行し、試行に結果を書く
/// （`docs/renewal/architecture.md` の「ジョブと試行」）。
///
/// 試行を「実行中」で作ってから Claude を呼び、終わるまで生きている印を書き続ける。ジョブの状態は書かない
/// （司令塔が試行を読んで決める）
public struct ClaudeJobWorker: Sendable {
    public var runner: ClaudeJobRunner
    public var recorder: AttemptRecorder
    public var timing: JobTiming
    public var sleeper: any Sleeper

    public init(runner: ClaudeJobRunner, recorder: AttemptRecorder, timing: JobTiming = JobTiming(), sleeper: any Sleeper = TaskSleeper()) {
        self.runner = runner
        self.recorder = recorder
        self.timing = timing
        self.sleeper = sleeper
    }

    /// ジョブを引き受けて実行し、終えた試行を返す。ほかで引き受けていて引き受けられなければ nil
    public func perform(_ job: JobFile) async throws(CommanderError) -> AttemptFile? {
        let attempt: AttemptFile
        do {
            attempt = try await recorder.start(job)
        } catch .alreadyExists {
            return nil
        } catch {
            throw .files(error)
        }
        let beating = Task { [recorder, timing, sleeper] in
            await Self.beat(attempt, of: job, recorder: recorder, interval: timing.heartbeatInterval, sleeper: sleeper)
        }
        let result: Result<ClaudeJobOutcome, CommanderError>
        do {
            result = .success(try await runner.run(job))
        } catch {
            result = .failure(error)
        }
        // 書いている途中の生きている印が終わるのを待ってから、終わりを書く（同じ試行のファイルへの書き込みをぶつけない）
        beating.cancel()
        await beating.value
        let (failure, session) = Self.record(of: result, now: runner.context.now())
        do {
            return try await recorder.finish(attempt, of: job, failure: failure, claude: session?.attemptRecord)
        } catch {
            // 終わりを書けなければ、試行は実行中のまま残り、司令塔が時間切れとして扱う
            throw .files(error)
        }
    }

    /// 試行に書く失敗と Claude の記録。結果を捨てたときも、ジョブとしては成功
    static func record(of result: Result<ClaudeJobOutcome, CommanderError>, now: Date) -> (AttemptFailure?, ClaudeSession?) {
        switch result {
        case let .success(.written(session)): (nil, session)
        case let .success(.discarded(_, session)): (nil, session)
        case let .success(.failed(failure, session)): (failure, session)
        case let .failure(error): (error.attemptFailure(now: now), nil)
        }
    }

    /// 止められるまで、決まった間隔で生きている印を書く
    private static func beat(
        _ attempt: AttemptFile,
        of job: JobFile,
        recorder: AttemptRecorder,
        interval: Duration,
        sleeper: any Sleeper
    ) async {
        var current = attempt
        while !Task.isCancelled {
            do {
                try await sleeper.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // 書けなくても続ける（次の間隔でまた書く。続けて書けなければ、司令塔が止まったとみなす）
            if let next = try? await recorder.beat(current, of: job) { current = next }
        }
    }
}

extension CommanderError {
    /// 状態リポジトリに書けなかったときの、試行の失敗の区分
    func attemptFailure(now: Date) -> AttemptFailure {
        switch self {
        case let .store(error), let .files(.store(error)):
            error.attemptFailure(now: now)
        case .files(.tooManyConflicts):
            AttemptFailure(failureClass: .githubOutage, message: "状態リポジトリの書き込みがぶつかり続けた")
        case let .changedWhileProcessing(path):
            AttemptFailure(failureClass: .flaky, message: "処理の途中で \(path) が変わった")
        case let .untrustedKeys(detail):
            AttemptFailure(failureClass: .unexpected, message: "公開鍵の一覧を信用できない（\(detail)）")
        case let .files(failure):
            AttemptFailure(failureClass: .unexpected, message: "状態リポジトリのファイルを扱えない（\(failure)）")
        }
    }
}

extension StateStoreError {
    func attemptFailure(now: Date) -> AttemptFailure {
        switch self {
        case let .rateLimited(wait), let .budgetExhausted(wait):
            let retryAt = Timestamp(now.addingTimeInterval(TimeInterval(wait.components.seconds)))
            return AttemptFailure(failureClass: .githubOutage, message: "GitHub の上限・書き込みの予算に達した", retryAt: retryAt)
        case .cancelled:
            // 司令塔を止めた（再起動・ログアウト）。失敗に数えず、戻ったら続きから試す
            return AttemptFailure(failureClass: .macOffline, message: "司令塔を止めたので、試行を中断した")
        case .unauthorized, .tokenUnavailable:
            return AttemptFailure(failureClass: .authExpired, message: "状態リポジトリのトークンが使えない")
        case .serverError, .transport, .conflict:
            return AttemptFailure(failureClass: .githubOutage, message: "状態リポジトリに届かない（\(self)）")
        default:
            return AttemptFailure(failureClass: .unexpected, message: "状態リポジトリを読み書きできない（\(self)）")
        }
    }
}
