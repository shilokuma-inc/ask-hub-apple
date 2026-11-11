import AskHubStateStore
import Foundation

/// 非常口の `askhub status --watch <秒>`。1 つのプロセスで決まった間隔ごとに読み直し、中身が変わったときだけ出す。
///
/// 同じ置き場所（`GitHubContentsStore`）を使い続けるので、直下の一覧の ETag と tree・blob を周をまたいで使い回す。変わらない周は直下の一覧の 304 だけで、
/// GitHub の上限に数えられない。外のループ（`while … sleep`）で `askhub status` を流すと、毎回プロセスが新しく、読んだものがすべて上限に数えられる
public struct StatusWatch: Sendable {
    /// これより短い間隔は断る。GitHub の上限（1 時間 5,000 回）はアカウントごとで、アプリ・司令塔・`gh` と分け合う
    public static let minimumInterval: Duration = .seconds(60)

    let interval: Duration
    let sleeper: any Sleeper
    let now: @Sendable () -> Date
    let read: @Sendable () async throws -> String
    let output: @Sendable (String) -> Void
    let problem: @Sendable (String) -> Void

    /// `read` は 1 周に読む中身、`output` は変わった中身を出す先、`problem` は読めなかったことを知らせる先
    public init(
        interval: Duration,
        sleeper: any Sleeper = TaskSleeper(),
        now: @escaping @Sendable () -> Date = { Date() },
        read: @escaping @Sendable () async throws -> String,
        output: @escaping @Sendable (String) -> Void,
        problem: @escaping @Sendable (String) -> Void
    ) {
        self.interval = interval
        self.sleeper = sleeper
        self.now = now
        self.read = read
        self.output = output
        self.problem = problem
    }

    /// `--watch <秒>` の間隔。無ければ nil
    public static func interval(_ arguments: CommandArguments) throws(CommandArguments.Failure) -> Duration? {
        guard arguments.values["watch"] != nil else { return nil }
        let seconds = try arguments.integer("watch")
        let minimum = minimumInterval.components.seconds
        guard seconds >= minimum else {
            throw CommandArguments.Failure(message: "--watch は \(minimum) 秒以上（GitHub の上限はアカウントごとで、アプリ・司令塔と分け合う）")
        }
        return .seconds(seconds)
    }

    /// 止められるまで続ける
    public func run() async throws {
        try await run(rounds: nil)
    }

    /// `rounds` 周したら終わる（nil なら止められるまで続ける）。最後の周の後は待たない
    func run(rounds: Int?) async throws {
        var shown: String?
        var round = 0
        while true {
            round += 1
            var wait = interval
            do {
                let report = try await read()
                if report != shown {
                    output("── \(now().formatted(.iso8601))\n\(report)")
                    shown = report
                }
            } catch {
                // 待っても変わらない失敗（トークンの期限切れ・権限・読めないファイルなど）は、繰り返さずに止める
                guard let retry = Self.wait(after: error) else { throw error }
                wait = max(wait, retry)
                problem("読めなかった（\(error)）。\(wait.components.seconds) 秒後に読み直す")
            }
            if let rounds, round >= rounds { return }
            try await sleeper.sleep(for: wait)
        }
    }

    /// 待てば読める失敗なら、待つ時間の下限。GitHub の上限は戻るまで待ち、GitHub の障害・通信の失敗は間隔のとおりに待つ
    static func wait(after error: any Error) -> Duration? {
        var storeError = error as? StateStoreError
        if case let .store(inner)? = error as? StateFileStore.Failure { storeError = inner }
        guard let storeError else { return nil }
        if let retryAfter = storeError.retryAfter { return retryAfter }
        switch storeError {
        case .serverError, .transport: return .zero
        default: return nil
        }
    }
}
