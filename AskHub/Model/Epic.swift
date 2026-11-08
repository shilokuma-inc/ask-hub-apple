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
    /// 作業場所の用意（開始した後の段取りの最初）。開始する前は nil
    var workspace: Workspace?
    /// 人が一時停止した時刻（再開するまで次の作業を始めない）。止めていなければ nil。
    /// Mac がオフラインで止まっているときは、`activities` の `.paused` で出す
    var pausedAt: Date?

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

    /// 作業場所の用意（作業ブランチを作る）
    enum Workspace: Hashable {
        /// 司令塔が開始を受け取る前
        case pending
        case preparing
        /// 人の対応を待って止まっている（「対処が要ります」）
        case failed
        /// 用意できた。作業ブランチが分からなければ nil
        case ready(branch: String?)
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
    /// 受け持つ Mac と、最後に動いた時刻。分からなければ nil
    var worker: Worker?

    struct Worker: Hashable {
        var macID: Mac.ID
        /// 試行の生きている印。Mac が引き受ける前は nil
        var heartbeatAt: Date?
    }

    enum Kind: Hashable {
        case writingQuestions
        case explaining(Question.ID)
        case reviewing(Question.ID)
        case checkingAnswers
        case revisingGoal
        /// 開始を送り、司令塔が受け取るのを待っている（選んだ Mac）
        case startRequested(macID: Mac.ID?)
        /// 開始した後の段取りの 1 つ（作業場所の用意・タスクの実装・レビュー・直し）
        case step(WorkStep, StepProgress)
        /// タスクがすべて終わり、最終 PR の段取りを待っている
        case tasksFinished
        /// 最終 PR の CI を待っている
        case waitingForCI(taskID: EpicTask.ID?)
        /// ランナー不足。人の対応は要らないので「あなたの番」には出さない
        case waitingForRunner(retry: Int, nextAt: Date)
        case usageLimit(until: Date)
        /// Mac がオフラインのため一時停止している
        case paused(macID: Mac.ID, since: Date)
        case fixingFinalPullRequest(FailureCategory, attempt: Int)
        case merging
        /// マージの承認を送り、司令塔が受け取るのを待っている
        case mergeRequested
        /// 最終 PR への指示を送り、司令塔が受け取るのを待っている
        case finalInstructionRequested
    }
}

/// 開始した後の段取りの 1 つ
enum WorkStep: Hashable {
    case prepareWorkspace
    case task(EpicTask.ID, EpicTask.Phase)
    /// タスクがすべて終わった後の、最終 PR の段取り
    case final(FinalStep)
}

/// 最終 PR の段取り（`docs/renewal/flows.md` の「最終 PR までの段取り」）。最終 PR の番号は、出す前と分からないときは nil
enum FinalStep: Hashable {
    /// 最終 PR で流すのと同じ検証（UI テストを含む）
    case verifying
    /// 仮決めを、見えるものと内部の細部に仕分ける
    case classifying
    /// 見える仮決めの Before / After を撮る
    case capturing
    case opening
    /// 最終 PR のチェックとレビューを待って、レビュー役が読んでいる
    case reviewing(pullRequest: Int?)
    /// 最終 PR を直している（直す理由。CI・レビュー・コンフリクトの直しは何回目か）
    case fixing(pullRequest: Int?, reason: FixReason)
    case merging(pullRequest: Int?)

    enum FixReason: Hashable {
        /// CI が通らない（何回目か）
        case checks(round: Int)
        /// レビュー役の必須の指摘（何回目か）
        case review(round: Int)
        /// base とのコンフリクト（何回目か）
        case conflict(round: Int)
        /// 人が頼んだ（判断のカードの「直してほしい」「別案にする」・最終 PR への指示）
        case request
    }
}

/// 段取りの進み具合
enum StepProgress: Hashable {
    /// Mac が引き受けるのを待っている
    case waitingForMac
    /// 人の対応を待っていたところに、やり直しを送った。司令塔が受け取るのを待っている
    case retryRequested
    /// 失敗の後、試し直す時刻を待っている
    case retrying(at: Date)
    /// Mac が進めている（試行の番号）
    case running(attempt: Int)
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
        /// 進めている。段階が分からなければ（司令塔が次のジョブを作る前など）nil
        case inProgress(Phase?)
        /// 人の対応を待って止まっている（「対処が要ります」）。子 PR を作った後なら、その番号（直すときに PR を見られるように）
        case failed(pullRequest: Int?)
        /// 子 PR の番号が分からないときは nil
        case done(pullRequest: Int?)
    }

    /// 進めているタスクの段階
    enum Phase: Hashable {
        case implementing
        /// 子 PR のチェックを待って、レビュー役が読んでいる（ワーカーは 2 つを書き分けないので、1 つにまとめる）
        case reviewing(pullRequest: Int?)
        /// 子 PR を直している（何回目か・直す理由）
        case fixing(pullRequest: Int?, round: Int, reason: FixReason?)
        /// 実装・直しの途中で Claude が聞いた質問の、人の答えを待っている（直しの途中なら、直している子 PR）
        case waitingForAnswer(question: Question.ID, pullRequest: Int?)
    }

    enum FixReason: Hashable {
        /// 子 PR のチェック（CI）が通らない
        case checks
        /// レビュー役の必須の指摘
        case review
    }

    /// 子 PR。作る前と、分からないときは nil
    var pullRequest: Int? {
        switch state {
        case .done(let number), .failed(let number), .inProgress(.reviewing(let number)?), .inProgress(.fixing(let number, _, _)?),
             .inProgress(.waitingForAnswer(_, let number)?):
            number

        case .pending, .locked, .inProgress:
            nil
        }
    }

    var isInProgress: Bool {
        if case .inProgress = state {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = state {
            return true
        }
        return false
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

    /// いま人の答えを待っている質問。開始する前は回答の段階の質問、開始した後は実装の途中の質問（答えるまで epic は止まっている）
    var awaitedQuestions: [Question] {
        if stage == .questions {
            return answerableQuestions
        }
        return isActive ? answerableQuestions.filter { $0.during != nil } : []
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

    /// 人が一時停止している（Mac がオフラインで止まっているだけのときは false）
    var isPaused: Bool { pausedAt != nil }
}
