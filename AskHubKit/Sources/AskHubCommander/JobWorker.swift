import AskHubClaude
import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation

/// ジョブを 1 回実行した結果（試行に書くもの）
public struct JobResult: Equatable, Sendable {
    /// 失敗のときだけ。成功・結果を捨てたとき（ジョブとしては成功）は nil
    public var failure: AttemptFailure?
    /// 外部の id（PR の番号・ブランチの名前・コミットなど）。やり直す前に、すでにできているかを確かめるのに使う
    public var outputs: AttemptFile.Outputs?
    /// Claude を呼んだときの記録
    public var claude: AttemptFile.Claude?

    public init(failure: AttemptFailure? = nil, outputs: AttemptFile.Outputs? = nil, claude: AttemptFile.Claude? = nil) {
        self.failure = failure
        self.outputs = outputs
        self.claude = claude
    }
}

/// ジョブを 1 回実行するもの（Claude のジョブ・作業場所の用意など、種類ごとに作る）
public protocol JobRunning: Sendable {
    /// 実行して、試行に書く結果を返す。状態リポジトリに書けないなど、やり直せば済む失敗は投げる（試行の失敗として書く）
    func execute(_ job: JobFile) async throws(CommanderError) -> JobResult
}

/// ワーカーとして、自分宛てのジョブを 1 つ引き受けて実行し、試行に結果を書く（`docs/renewal/architecture.md` の「ジョブと試行」）。
/// 司令塔（常時オンの Mac）とワーカー（`askhub-worker`）で使う。
///
/// 試行を「実行中」で作ってから実行し、終わるまで生きている印を書き続ける。ジョブの状態は書かない
/// （司令塔が試行を読んで決める）
public struct JobWorker: Sendable {
    public var runner: any JobRunning
    public var recorder: AttemptRecorder
    public var timing: JobTiming
    public var sleeper: any Sleeper
    public var now: @Sendable () -> Date

    public init(
        runner: any JobRunning,
        recorder: AttemptRecorder,
        timing: JobTiming = JobTiming(),
        sleeper: any Sleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runner = runner
        self.recorder = recorder
        self.timing = timing
        self.sleeper = sleeper
        self.now = now
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
        let result: JobResult
        do {
            result = try await runner.execute(job)
        } catch {
            result = JobResult(failure: error.attemptFailure(now: now()))
        }
        // 書いている途中の生きている印が終わるのを待ってから、終わりを書く（同じ試行のファイルへの書き込みをぶつけない）
        beating.cancel()
        await beating.value
        do {
            return try await finish(attempt, of: job, with: result)
        } catch {
            // 終わりを書けなければ、試行は実行中のまま残り、司令塔が時間切れとして扱う
            throw .files(error)
        }
    }

    /// 終わりを書く。書き込みの予算・GitHub の上限に当たったら、待って書き直す（終えた試行の結果を捨てない）
    private func finish(
        _ attempt: AttemptFile,
        of job: JobFile,
        with result: JobResult
    ) async throws(StateFileStore.Failure) -> AttemptFile {
        var waited = Duration.zero
        while true {
            do {
                return try await recorder.finish(attempt, of: job, failure: result.failure, outputs: result.outputs, claude: result.claude)
            } catch let .store(error) {
                guard let wait = error.retryAfter, waited + wait <= timing.writeWaitLimit else { throw .store(error) }
                do {
                    try await sleeper.sleep(for: wait)
                } catch {
                    throw .store(.cancelled)
                }
                waited += wait
            }
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

extension ClaudeJobRunner: JobRunning {
    /// 試行に書く結果。結果を捨てたときも、ジョブとしては成功
    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        switch try await run(job) {
        case let .written(session): JobResult(claude: session.attemptRecord)
        case let .discarded(_, session): JobResult(claude: session?.attemptRecord)
        case let .failed(failure, session): JobResult(failure: failure, claude: session?.attemptRecord)
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
