import Foundation

/// どのチェックを、どう待つか
public struct CheckPolicy: Sendable, Equatable {
    /// 待つチェックの名前（check run の名前か commit status の context）。nil ならすべて。
    /// 一覧に無いチェックは見ない。空の集合なら何も待たない
    public var required: Set<String>?
    /// queued のままこれより長いチェックは、ランナー不足とみなす
    public var queuedLimit: Duration

    public init(required: Set<String>? = nil, queuedLimit: Duration = .seconds(30 * 60)) {
        self.required = required
        self.queuedLimit = queuedLimit
    }
}

/// head の SHA の CI をまとめた状態
public struct CheckSummary: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        /// 終わっていないチェックがある、または待つチェックがまだ出ていない
        case pending
        /// 待つチェックがすべて成功した（neutral・skipped を含む）
        case passed
        /// 落ちたチェックがある。終わっていないチェックが残ることがある（直させる前に `unfinished` が空になるのを待つとよい）
        case failed
        /// 落ちたチェックは無く、queued のまま `queuedLimit` より長いチェックがある
        case runnerShortage
    }

    public var verdict: Verdict
    public var failures: [FailedCheck]
    /// まだ終わっていないチェックの名前（queued を含む）
    public var unfinished: [String]
    /// 待つ一覧にあるのに、まだ 1 度も出ていないチェックの名前
    public var missing: [String]
    /// queued のまま `queuedLimit` より長いチェックの名前
    public var starved: [String]

    public init(verdict: Verdict, failures: [FailedCheck] = [], unfinished: [String] = [], missing: [String] = [], starved: [String] = []) {
        self.verdict = verdict
        self.failures = failures
        self.unfinished = unfinished
        self.missing = missing
        self.starved = starved
    }
}

/// 落ちたチェック
public struct FailedCheck: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case checkRun
        case commitStatus
    }

    public var name: String
    public var source: Source
    /// check run の conclusion（`failure`・`timed_out`・`cancelled` など）か、commit status の state（`failure`・`error`）
    public var conclusion: String
    /// GitHub Actions の run の id（`rerunFailedJobs(runID:)` に渡す）。Actions 以外は nil
    public var runID: Int?
    /// GitHub Actions の job の id（ログを読むのに使う）。Actions 以外は nil
    public var jobID: Int?
    public var detailsURL: URL?

    public init(name: String, source: Source, conclusion: String, runID: Int? = nil, jobID: Int? = nil, detailsURL: URL? = nil) {
        self.name = name
        self.source = source
        self.conclusion = conclusion
        self.runID = runID
        self.jobID = jobID
        self.detailsURL = detailsURL
    }
}

/// 1 つのチェックの今の様子（check run と commit status をそろえた形）
struct ObservedCheck: Sendable, Equatable {
    enum Progress: Sendable, Equatable {
        /// ランナーを待っている。`since` は待ち始めた時刻（分からなければ nil）
        case queued(since: Date?)
        case running
        case succeeded
        case failed(FailedCheck)
    }

    var name: String
    var progress: Progress

    /// 同じ名前のチェックが複数あれば（push と pull_request の両方で同じワークフローが走るなど）、すべてを見る。
    /// 1 つでも落ちていれば落ちたとみなす
    static func summarize(_ checks: [Self], policy: CheckPolicy, now: Date) -> CheckSummary {
        let considered = policy.required.map { names in checks.filter { names.contains($0.name) } } ?? checks
        let seen = Set(considered.map(\.name))
        let missing = policy.required.map { $0.subtracting(seen).sorted() } ?? []
        var failures: [FailedCheck] = []
        var unfinished: [String] = []
        var starved: [String] = []
        for check in considered {
            switch check.progress {
            case let .failed(failure):
                failures.append(failure)
            case let .queued(since):
                unfinished.append(check.name)
                if let since, now.timeIntervalSince(since) > policy.queuedLimit.seconds { starved.append(check.name) }
            case .running:
                unfinished.append(check.name)
            case .succeeded:
                break
            }
        }
        // 何も出ていない（CI がまだ始まっていない）のを成功とみなさない
        let nothingYet = policy.required == nil && considered.isEmpty
        let verdict: CheckSummary.Verdict = if !failures.isEmpty {
            .failed
        } else if !starved.isEmpty {
            .runnerShortage
        } else if !unfinished.isEmpty || !missing.isEmpty || nothingYet {
            .pending
        } else {
            .passed
        }
        return CheckSummary(
            verdict: verdict,
            failures: failures,
            unfinished: Self.unique(unfinished),
            missing: missing,
            starved: Self.unique(starved)
        )
    }

    /// 順を保って重なりを除く
    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }
}

extension Duration {
    /// 秒（小数を含む）
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
