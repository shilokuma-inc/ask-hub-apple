import AskHubKit
import Foundation

/// 第三者レビューの対象にするかを決めるための、最終 PR（`epic-final`）の今の状態
public struct FinalReviewCandidate: Sendable, Equatable {
    public let pullRequest: FinalReviewPullRequest
    /// 今の head の CodeRabbit の状態
    public let codeRabbit: EpicPullRequest.CodeRabbitState
    /// 既定ブランチとコンフリクトしているか（解消で head が変わるので、レビューしない）
    public let isConflicting: Bool
    /// 信用する author が書いた今の head の第三者レビュー（無ければ `nil`）
    public let thirdPartyReview: ThirdPartyReviewMarker?

    public init(
        pullRequest: FinalReviewPullRequest,
        codeRabbit: EpicPullRequest.CodeRabbitState,
        isConflicting: Bool,
        thirdPartyReview: ThirdPartyReviewMarker? = nil
    ) {
        self.pullRequest = pullRequest
        self.codeRabbit = codeRabbit
        self.isConflicting = isConflicting
        self.thirdPartyReview = thirdPartyReview
    }
}

extension FinalReviewPullRequest {
    /// PR を見分けるキー（リポジトリ名は小文字）
    var key: String {
        "\(repository.lowercased())#\(number)"
    }
}

/// 最終 PR の第三者レビューの進み具合を覚える（副作用なし。Discussion #503）。
///
/// - head が変わってから `codeRabbitWait`（10 分）経っても CodeRabbit のレビューが完了しないか、CodeRabbit がレート制限・失敗・スキップなら第三者レビューを始める
/// - 要修正があれば修正させ、修正の push で head が変わったらまたレビューする。要修正が `maxAttempts`（3 回）続いたらあきらめる
/// - CodeRabbit が今の head をレビューしたら、第三者レビュー・修正はやめる（済み（CodeRabbit）。Q2）
/// - head が変わったら待ち始めからやり直す（Q3）。要修正が続いた回数は、自分の修正の push で変わったときだけ引き継ぎ、
///   人の push・コンフリクトの解消・develop の取り込みで変わったときは 0 に戻す（人が直して push すればまた回る。Q1）
public struct FinalReviewTracker: Sendable {
    /// head が変わってから CodeRabbit のレビューを待つ時間
    public static let codeRabbitWait: Duration = .seconds(10 * 60)
    /// 要修正がこの回数続いたらあきらめる
    public static let maxAttempts = 3
    /// レビュー・修正のコマンドが同じ head でこの回数続けて失敗したらあきらめる
    public static let maxFailures = 3

    /// 裏で行うこと
    public enum Action: Sendable, Equatable {
        case review
        case fix
    }

    /// 今から始めること 1 件
    public struct Start: Sendable {
        public let pullRequest: FinalReviewPullRequest
        public let repository: RepositoryConfig
        public let action: Action
    }

    /// 第三者レビューのコマンドの結果
    public enum ReviewOutcome: Sendable, Equatable {
        /// レビューして PR にコメントした
        case reviewed(must: Int, may: Int)
        /// head が進んでいたのでレビューしなかった
        case stale
        case failed(reason: String)
    }

    /// 修正のコマンドの結果
    public enum FixOutcome: Sendable, Equatable {
        /// 要修正を直して push した（新しい head）
        case fixed(head: String)
        /// head が進んでいたので直さなかった
        case stale
        case failed(reason: String)
    }

    struct Entry: Sendable, Equatable {
        /// 追跡している head
        var head: String
        /// この head を見始めた時刻（CodeRabbit を待ち始めた時刻）
        var since: Date
        var state: FinalReviewMarker.State = .waiting
        /// 要修正が続いた回数
        var attempts = 0
        /// 今の head でコマンドが続けて失敗した回数
        var failures = 0
        /// 修正の push で次になるはずの head（自分の push か人の push かを見分ける）
        var pushedHead: String?
        /// コマンドが head が進んだ（`stale`）と返した。新しい head が見えるまで、古い head では始めない
        var awaitingNewHead = false
    }

    private(set) var entries: [String: Entry] = [:]
    /// レビュー・修正を実行中のリポジトリ（名前の小文字）
    private(set) var runningRepositories: Set<String> = []

    public init() {}

    /// ポーリングで取得した最終 PR の状態を取り込む。一覧に無い PR（マージ・クローズ済み）は忘れる
    public mutating func update(with candidates: [FinalReviewCandidate], now: Date) {
        var updated: [String: Entry] = [:]
        for candidate in candidates {
            let head = candidate.pullRequest.headSHA.lowercased()
            var entry: Entry
            if let previous = entries[candidate.pullRequest.key], previous.head == head {
                entry = previous
            } else {
                // 新しい PR か、head が変わった。待ち始めからやり直す
                let previous = entries[candidate.pullRequest.key]
                let pushedByFix = previous?.pushedHead.map { $0 == head } ?? false
                entry = Entry(head: head, since: now, attempts: pushedByFix ? previous?.attempts ?? 0 : 0)
            }
            if candidate.codeRabbit == .completed {
                // CodeRabbit が今の head をレビューしたら、第三者レビュー・修正はやめる（Q2）
                entry.state = .doneCodeRabbit
            } else if let review = candidate.thirdPartyReview, review.sha == head, review.isClean, entry.state != .gaveUp {
                entry.state = .done
            }
            updated[candidate.pullRequest.key] = entry
        }
        entries = updated
    }

    /// 今から始めること。担当リポジトリの PR で、コンフリクトしていないもの。
    /// レビュー・修正はメインの checkout に一時 worktree を作るので、同じリポジトリでは 1 件ずつにする
    /// （`busyRepositories`（コンフリクトの解消を実行中など）と実行中のリポジトリのものは選ばず、リポジトリごとに 1 件まで）
    public func startable(
        in candidates: [FinalReviewCandidate],
        config: OrchestratorConfig,
        now: Date,
        busyRepositories: Set<String> = []
    ) -> [Start] {
        var chosen = runningRepositories.union(busyRepositories.map { $0.lowercased() })
        var startable: [Start] = []
        for candidate in candidates where !candidate.isConflicting {
            let pullRequest = candidate.pullRequest
            let repositoryKey = pullRequest.repository.lowercased()
            guard !chosen.contains(repositoryKey),
                  let repository = config.repository(named: pullRequest.repository),
                  let entry = entries[pullRequest.key], entry.head == pullRequest.headSHA.lowercased(),
                  let action = Self.action(for: entry, candidate: candidate, now: now) else {
                continue
            }
            chosen.insert(repositoryKey)
            startable.append(Start(pullRequest: pullRequest, repository: repository, action: action))
        }
        return startable
    }

    /// その PR で今行うこと（無ければ `nil`）
    private static func action(for entry: Entry, candidate: FinalReviewCandidate, now: Date) -> Action? {
        // CodeRabbit が今の head をレビューしたら始めない（Q2）。head が進んだと分かったら、新しい head が見えるまで待つ
        if candidate.codeRabbit == .completed || entry.awaitingNewHead {
            return nil
        }
        switch entry.state {
        case .waiting:
            let codeRabbitCannotReview = [.rateLimited, .failed, .skipped].contains(candidate.codeRabbit)
            let waited = entry.since.addingTimeInterval(TimeInterval(codeRabbitWait.components.seconds)) <= now
            return codeRabbitCannotReview || waited ? .review : nil

        case .fixing:
            // 修正を push した後は、新しい head が見えるまで直し直さない
            return entry.pushedHead == nil ? .fix : nil

        case .reviewing, .done, .doneCodeRabbit, .gaveUp:
            return nil
        }
    }

    /// レビュー・修正を始めた。終わるまで、同じリポジトリのほかの PR は選ばない
    public mutating func start(_ action: Action, for pullRequest: FinalReviewPullRequest) {
        runningRepositories.insert(pullRequest.repository.lowercased())
        if action == .review, var entry = entries[pullRequest.key], entry.head == pullRequest.headSHA.lowercased() {
            entry.state = .reviewing
            entries[pullRequest.key] = entry
        }
    }

    /// レビュー・修正が終わった（結果を記録しないとき（利用上限で終わったなど）も呼ぶ）。
    /// 結果を記録せずに終えたレビューは、待っている状態に戻して次に試し直す
    public mutating func finish(_ pullRequest: FinalReviewPullRequest) {
        runningRepositories.remove(pullRequest.repository.lowercased())
        if var entry = entries[pullRequest.key], entry.state == .reviewing {
            entry.state = .waiting
            entries[pullRequest.key] = entry
        }
    }

    /// そのリポジトリでレビュー・修正を実行中か
    public func isRunning(in repository: String) -> Bool {
        runningRepositories.contains(repository.lowercased())
    }

    /// レビューの結果を記録する。あきらめることになったら `true`。
    /// レビューした head がもう追跡している head でないとき・CodeRabbit が先にレビューした（済み（CodeRabbit））ときは何もしない
    @discardableResult
    public mutating func record(_ outcome: ReviewOutcome, for pullRequest: FinalReviewPullRequest) -> Bool {
        guard var entry = entries[pullRequest.key], entry.head == pullRequest.headSHA.lowercased(),
              entry.state != .doneCodeRabbit else {
            return false
        }
        switch outcome {
        case let .reviewed(must, _):
            entry.failures = 0
            if must == 0 {
                entry.state = .done
            } else {
                entry.attempts += 1
                entry.state = entry.attempts >= Self.maxAttempts ? .gaveUp : .fixing
            }

        case .stale:
            // 次の取得で新しい head から待ち直す
            entry.state = .waiting
            entry.awaitingNewHead = true

        case .failed:
            entry.failures += 1
            entry.state = entry.failures >= Self.maxFailures ? .gaveUp : .waiting
        }
        entries[pullRequest.key] = entry
        return entry.state == .gaveUp
    }

    /// 修正の結果を記録する。あきらめることになったら `true`。
    /// 直した head がもう追跡している head でないとき・CodeRabbit が先にレビューしたときは何もしない
    @discardableResult
    public mutating func record(_ outcome: FixOutcome, for pullRequest: FinalReviewPullRequest) -> Bool {
        guard var entry = entries[pullRequest.key], entry.head == pullRequest.headSHA.lowercased(),
              entry.state != .doneCodeRabbit else {
            return false
        }
        switch outcome {
        case let .fixed(head) where head.lowercased() != entry.head:
            entry.failures = 0
            entry.pushedHead = head.lowercased()

        case .fixed, .failed:
            // 今の head と同じ SHA を「直した」と返したときも、直っていないので失敗に数える
            entry.failures += 1
            if entry.failures >= Self.maxFailures {
                entry.state = .gaveUp
            }

        case .stale:
            entry.state = .waiting
            entry.awaitingNewHead = true
        }
        entries[pullRequest.key] = entry
        return entry.state == .gaveUp
    }

    /// 最終 PR に書き出す進み具合（追跡していなければ `nil`）
    public func marker(for pullRequest: FinalReviewPullRequest) -> FinalReviewMarker? {
        guard let entry = entries[pullRequest.key] else {
            return nil
        }
        return FinalReviewMarker(state: entry.state, sha: entry.head, attempts: entry.attempts)
    }

    /// 第三者レビューのコマンドの出力の最後の `ASKHUB_RESULT:` の行から結果を読む
    public static func reviewOutcome(in output: String) -> ReviewOutcome? {
        guard let value = resultValue(in: output) else {
            return nil
        }
        if value == "stale" {
            return .stale
        }
        if value.hasPrefix("failed") {
            return .failed(reason: reason(value.dropFirst("failed".count)))
        }
        guard let match = value.wholeMatch(of: /reviewed must=([0-9]+) may=([0-9]+)/),
              let must = Int(match.output.1), let may = Int(match.output.2) else {
            return nil
        }
        return .reviewed(must: must, may: may)
    }

    /// 修正のコマンドの出力の最後の `ASKHUB_RESULT:` の行から結果を読む
    public static func fixOutcome(in output: String) -> FixOutcome? {
        guard let value = resultValue(in: output) else {
            return nil
        }
        if value == "stale" {
            return .stale
        }
        if value.hasPrefix("failed") {
            return .failed(reason: reason(value.dropFirst("failed".count)))
        }
        guard let match = value.wholeMatch(of: /fixed ([0-9a-fA-F]{40})/) else {
            return nil
        }
        return .fixed(head: String(match.output.1).lowercased())
    }

    private static func resultValue(in output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix("ASKHUB_RESULT:") }) else {
            return nil
        }
        return line.dropFirst("ASKHUB_RESULT:".count).trimmingCharacters(in: .whitespaces)
    }

    private static func reason(_ text: Substring) -> String {
        let reason = text.trimmingCharacters(in: .whitespaces)
        return reason.isEmpty ? "理由は出力されませんでした" : reason
    }
}
