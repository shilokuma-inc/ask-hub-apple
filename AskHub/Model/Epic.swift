import Foundation

/// 1 つの依頼から最終 PR のマージまでのまとまり。クライアントの画面の中心
struct Epic: Identifiable, Hashable {
    let id: String
    var title: String
    var repositoryID: TargetRepository.ID
    var request: EpicRequest
    var stage: Stage
    var questions: [Question]
    var goal: Goal?
    var humanTasks: [HumanTask]
    var tasks: [EpicTask]
    /// 実装を回す Mac（開始のときに人が選ぶ）
    var macID: Mac.ID?
    /// 機械がいましていること（複数のことがある。例: Q4 の説明を書きながら Q5 を見直す）
    var activities: [EpicActivity]
    /// 自動の対処を使い切って、人に渡された失敗
    var blocker: Blocker?
    var finalReview: FinalReview?
    var history: [HistoryEntry]
    var updatedAt: Date
    /// 着手前の確認で、1 つの epic に収まらないと分かったとき
    var split: SplitProposal?
    /// やめた（分けて依頼し直した など）。段階は、やめたときの段階のまま持つ
    var isAbandoned = false

    /// 段階。画面の段階の帯は 依頼・質問・確認（着手前の確認とゴール）・実装・最終 PR・完了 の 6 つ
    enum Stage: Int, Hashable, CaseIterable, Comparable {
        /// 依頼を受け、Claude が質問を作っている
        case request
        case questions
        /// 着手前の確認（Claude が回答一式を確かめている）
        case preflight
        /// ゴールを人が確かめて開始を押す
        case goal
        case implementing
        case finalReview
        case done

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct HistoryEntry: Hashable {
        var date: Date
        var text: String
        var isFailure = false
    }
}

/// 着手前の確認で 1 つの epic に収まらないと分かったときの、理由と分け方の案
struct SplitProposal: Hashable {
    var reason: String
    /// 分け方の案。決めきれない点があって分け方を出せないときは空
    var parts: [Part]
    /// 人が選んだ判断。まだなら nil
    var choice: SplitChoice?

    struct Part: Hashable {
        var title: String
        var summary: String
    }
}

/// 元の依頼
struct EpicRequest: Hashable {
    var summary: String
    var body: String
    var requestedAt: Date
    var source: Source
    var attachmentCount: Int

    enum Source: Hashable {
        case app
        case siri
    }
}

/// 機械がいましていること
struct EpicActivity: Hashable {
    var kind: Kind
    var since: Date

    enum Kind: Hashable {
        case writingQuestions
        case explaining(Question.ID)
        case reviewing(Question.ID)
        case checkingAnswers
        case revisingGoal
        case implementing(taskID: EpicTask.ID, attempt: Int)
        case waitingForCI(taskID: EpicTask.ID?)
        /// ランナー不足。人の対応は要らないので「あなたの番」には出さない
        case waitingForRunner(retry: Int, nextAt: Date)
        case usageLimit(until: Date)
        /// Mac がオフラインのため一時停止している
        case paused(macID: Mac.ID, since: Date)
        case fixingFinalPullRequest(FailureCategory, attempt: Int)
        case merging
    }
}

/// ゴールのタスク（実装の単位）
struct EpicTask: Identifiable, Hashable {
    let id: String
    var number: Int
    var title: String
    var state: State

    enum State: Hashable {
        case pending
        /// 人がする作業などが前提で、まだ始められない
        case locked(reason: String)
        case inProgress
        case failed
        /// 子 PR の番号が分からないときは nil
        case done(pullRequest: Int?)
    }
}

/// 失敗の区分。区分ごとに既定の扱い（再試行・人に渡す）が決まっている
enum FailureCategory: Hashable, CaseIterable {
    case runnerShortage
    case flaky
    case build
    case review
    case conflict
    case usageLimit
    case authExpired
    case githubOutage
    /// Claude の API の障害（混み合い・5xx・つながらない）
    case claudeOutage
    case macOffline
    case timeout
    case unexpected

    var label: String {
        switch self {
        case .runnerShortage: "ランナー不足"
        case .flaky: "揺らぎ"
        case .build: "ビルド・テスト"
        case .review: "レビューの指摘"
        case .conflict: "コンフリクト"
        case .usageLimit: "利用上限"
        case .authExpired: "認証切れ"
        case .githubOutage: "GitHub の障害"
        case .claudeOutage: "Claude の障害"
        case .macOffline: "Mac がオフライン"
        case .timeout: "時間切れ"
        case .unexpected: "想定外"
        }
    }
}

/// 人に渡された失敗。何が起きて何を試したかと、その場で選べる操作を持つ
struct Blocker: Hashable {
    var category: FailureCategory
    /// 例: ビルドが通りません
    var title: String
    var summary: String
    var logExcerpt: String?
    var attempts: [Attempt]
    var occurredAt: Date
    var actions: [Action]
    /// 止まっている作業の名前（例: Q3 の説明）。その作業だけをやめるボタンに出す。分からなければ nil
    var subject: String?
    /// 操作の対象（状態リポジトリではジョブと試行の番号）。送るまでに対象が替わっていないかを確かめるのに使う。デモでは nil
    var target: String?

    struct Attempt: Identifiable, Hashable {
        var id: Int { number }
        var number: Int
        var macName: String
        var startedAt: Date
        var endedAt: Date
        var outcome: String
    }

    enum Action: Hashable {
        /// 指示を添えて、さらに直させる
        case fixWithInstruction
        /// そのままもう一度試す
        case retry
        /// ほかの Mac で続ける
        case handOver
        /// 再認証など、人が自分で直してから再開する
        case resumeAfterFix
        case pause
        /// 止まっている作業だけをやめ、epic は続ける（例: 説明をやめて質問に戻す）
        case cancelJob
        /// epic をやめる
        case discard
    }
}

extension Epic {
    func question(_ id: Question.ID) -> Question? {
        questions.question(id)
    }

    func humanTask(_ id: HumanTask.ID) -> HumanTask? {
        humanTasks.first { $0.id == id }
    }

    var answerableQuestions: [Question] {
        questions.filter(\.isAnswerable)
    }

    var doneTaskCount: Int {
        tasks.filter {
            if case .done = $0.state {
                return true
            }
            return false
        }
        .count
    }

    var isActive: Bool { stage != .done && !isAbandoned }
}
