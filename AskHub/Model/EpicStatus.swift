import Foundation

/// epic の「いま」の 1 行。人が待たれているのか、機械が進めているのかを分けて出す
struct EpicStatusLine: Hashable {
    var owner: Owner
    var text: String
    var systemImage: String
    /// 押したときに開く画面
    var route: AppRoute?
    /// 添える小さな文（例: 最後の動き 3 分前 · 試行 2）
    var detail: String?

    enum Owner: Hashable {
        case you
        case machine
        case finished
        /// やめた（終わったが、作ったものは入らない）
        case abandoned
    }
}

/// epic の状態から「いま」の行を組み立てる
enum EpicStatus {
    static func lines(for epic: Epic, in snapshot: ClientSnapshot, now: Date) -> [EpicStatusLine] {
        if epic.isAbandoned {
            return [EpicStatusLine(owner: .abandoned, text: "やめました", systemImage: "xmark.seal.fill", route: nil)]
        }
        if epic.stage == .done {
            return [finishedLine(epic)]
        }
        let machineLines = epic.activities.map { machineLine($0, epic: epic, snapshot: snapshot, now: now) }
        return humanLines(epic) + pausedLines(epic, now: now) + machineLines
    }

    /// 人が一時停止しているか（進行中の一覧の区分に使う）。人が待たれているものは、そちらに出す
    static func isPausedByYou(_ epic: Epic) -> Bool {
        epic.isActive && epic.isPaused && !waitsForYou(epic)
    }

    /// 人が一時停止しているときの 1 行。動いている作業は最後まで終わるので、その段取りの行は下に続けて出す
    private static func pausedLines(_ epic: Epic, now: Date) -> [EpicStatusLine] {
        guard let pausedAt = epic.pausedAt else {
            return []
        }
        let text = "一時停止しています（\(RelativeTime.duration(since: pausedAt, now: now))）。再開するまで次の作業を始めません"
        return [EpicStatusLine(owner: .machine, text: text, systemImage: "pause.circle.fill", route: nil)]
    }

    /// 人が待たれているか（進行中の一覧の区分に使う）
    static func waitsForYou(_ epic: Epic) -> Bool {
        !humanLines(epic).isEmpty
    }

    private static func humanLines(_ epic: Epic) -> [EpicStatusLine] {
        var lines: [EpicStatusLine] = []
        if let blocker = epic.blocker {
            lines.append(you("対処が要ります: \(blocker.title)", "exclamationmark.triangle.fill", route: .epic(epic.id)))
        }
        let awaited = epic.awaitedQuestions
        if let point = awaited.first?.during {
            lines.append(you("\(point.label)の途中の質問の回答を待っています", "questionmark.bubble.fill", route: .deck(.questions(epic.id))))
        } else if !awaited.isEmpty {
            lines.append(you("あなたの回答を待っています（\(awaited.count) 問）", "questionmark.bubble.fill", route: .deck(.questions(epic.id))))
        }
        if epic.stage == .goal, let goal = epic.goal, !goal.isRevising {
            lines.append(you("ゴールの確認と開始を待っています", "flag.fill", route: .goal(epic.id)))
        }
        for task in epic.humanTasks where task.needsHuman {
            lines.append(you("人がする作業: \(task.title)", "wrench.fill", route: .humanTask(epicID: epic.id, taskID: task.id)))
        }
        if epic.stage == .finalReview, let review = epic.finalReview, review.state == .reviewable {
            if !review.pendingDecisions.isEmpty {
                lines.append(you("判断 \(review.pendingDecisions.count) 件の確認を待っています", "rectangle.stack.fill", route: .finalReview(epic.id)))
            } else if review.canMerge, review.mergePolicy != .automatic {
                lines.append(you("マージを待っています", "arrow.triangle.merge", route: .finalReview(epic.id)))
            }
        }
        return lines
    }

    private static func you(_ text: String, _ systemImage: String, route: AppRoute) -> EpicStatusLine {
        EpicStatusLine(owner: .you, text: text, systemImage: systemImage, route: route)
    }

    private static func finishedLine(_ epic: Epic) -> EpicStatusLine {
        var text = "終わりました"
        if case .merged(_, let automatic) = epic.finalReview?.state {
            text = automatic ? "自動でマージしました" : "マージしました"
        }
        return EpicStatusLine(owner: .finished, text: text, systemImage: "checkmark.seal.fill", route: nil)
    }

    static func machineLine(_ activity: EpicActivity, epic: Epic, snapshot: ClientSnapshot, now: Date) -> EpicStatusLine {
        let macName = snapshot.mac(activity.worker?.macID ?? epic.macID)?.name ?? activity.worker?.macID ?? "Mac"
        switch activity.kind {
        case let .step(step, progress):
            let (text, symbol) = describe(step, progress, epic: epic, macName: macName)
            return EpicStatusLine(owner: .machine, text: text, systemImage: symbol, route: nil, detail: detail(of: activity, now: now))

        default:
            let (text, symbol) = describe(activity.kind, epic: epic, macName: macName, snapshot: snapshot, now: now)
            return EpicStatusLine(owner: .machine, text: text, systemImage: symbol, route: nil)
        }
    }

    /// Mac が進めている段取りの、最後に動いた時刻と試行の番号
    private static func detail(of activity: EpicActivity, now: Date) -> String? {
        guard case .step(_, .running(let attempt)) = activity.kind else {
            return nil
        }
        let parts = [
            activity.worker?.heartbeatAt.map { "最後の動き \(RelativeTime.string($0, now: now))" },
            attempt > 1 ? "試行 \(attempt)" : nil
        ]
        let detail = parts.compactMap(\.self).joined(separator: " · ")
        return detail.isEmpty ? nil : detail
    }

    private static func describe(
        _ kind: EpicActivity.Kind,
        epic: Epic,
        macName: String,
        snapshot: ClientSnapshot,
        now: Date
    ) -> (String, String) {
        switch kind {
        case .writingQuestions:
            return ("Claude が質問を作っています", "ellipsis.bubble")

        case .explaining(let questionID):
            return ("Claude が \(questionID) の説明を書いています", "text.bubble")

        case .reviewing(let questionID):
            return ("Claude が \(questionID) を見直しています", "arrow.triangle.2.circlepath")

        case .checkingAnswers:
            return ("Claude が回答一式を確かめています（着手前の確認）", "checklist")

        case .revisingGoal:
            return ("Claude がゴールを直しています", "pencil")

        case .startRequested(let macID):
            let name = snapshot.mac(macID)?.name ?? macID ?? macName
            return ("\(name) での開始を送りました。司令塔が受け取るのを待っています", "paperplane")

        case .tasksFinished:
            return ("タスクがすべて終わりました。最終 PR の段取りを待っています", "checkmark.circle")

        case .mergeRequested:
            return ("マージの承認を送りました。司令塔が受け取るのを待っています", "paperplane")

        case .finalInstructionRequested:
            return ("最終 PR への指示を送りました。司令塔が受け取るのを待っています", "paperplane")

        default:
            return describeImplementation(kind, epic: epic, macName: macName, snapshot: snapshot, now: now)
        }
    }

    private static func describeImplementation(
        _ kind: EpicActivity.Kind,
        epic: Epic,
        macName: String,
        snapshot: ClientSnapshot,
        now: Date
    ) -> (String, String) {
        switch kind {
        case .waitingForCI:
            return ("CI を待っています", "clock")

        case let .waitingForRunner(retry, nextAt):
            return ("ランナーの空きを待っています（再試行 \(retry) 回目・次は \(RelativeTime.clock(nextAt))）", "hourglass")

        case .usageLimit(let until):
            return ("Claude の利用上限のため、\(RelativeTime.clock(until)) まで待っています", "gauge.with.dots.needle.100percent")

        case let .paused(macID, since):
            let name = snapshot.mac(macID)?.name ?? macName
            return ("一時停止: \(name) がオフラインです（\(RelativeTime.duration(since: since, now: now))）", "pause.circle")

        case let .fixingFinalPullRequest(category, attempt):
            return ("最終 PR の\(category.label)を直しています（\(attempt) / 3）", "wrench.and.screwdriver")

        case .merging:
            return ("マージしています", "arrow.triangle.merge")

        default:
            return ("", "circle")
        }
    }

    // MARK: 開始した後の段取り

    /// 段取りの 1 行。最後に動いた時刻は `detail(of:now:)` で添える
    private static func describe(_ step: WorkStep, _ progress: StepProgress, epic: Epic, macName: String) -> (String, String) {
        switch progress {
        case .running:
            let (doing, symbol) = doing(step, epic: epic)
            return ("\(macName) で\(doing)", symbol)

        case .waitingForMac:
            return ("\(macName) が\(name(of: step, epic: epic))を引き受けるのを待っています", "hourglass")

        case .retrying(let date):
            return ("\(name(of: step, epic: epic))を \(RelativeTime.clock(date)) に試し直します", "clock.arrow.circlepath")

        case .retryRequested:
            return ("\(name(of: step, epic: epic))のやり直しを送りました。司令塔が受け取るのを待っています", "paperplane")
        }
    }

    /// 進めている段取り（例: タスク 2/5「並べ替えのボタン」を実装しています）。子 PR の段階は、題を省いて PR の番号を出す
    private static func doing(_ step: WorkStep, epic: Epic) -> (String, String) {
        switch step {
        case .prepareWorkspace:
            return ("作業場所を用意しています", "folder.badge.gearshape")

        case let .task(taskID, phase):
            switch phase {
            case .implementing:
                return ("\(taskLabel(taskID, epic: epic))を実装しています", "hammer")

            case .reviewing(let pullRequest):
                let pullRequest = pullRequestLabel(taskID, pullRequest, epic: epic)
                return ("\(pullRequest) のチェックを待って、レビューしています", "eye")

            case let .fixing(pullRequest, round, reason):
                let pullRequest = pullRequestLabel(taskID, pullRequest, epic: epic)
                return ("\(pullRequest) の\(spaced(fixLabel(reason)))を直しています（\(round) 回目）", "wrench.and.screwdriver")

            case .waitingForAnswer(let question, _):
                return ("\(taskLabel(taskID, epic: epic))の途中の質問 \(question) の回答を待っています", "questionmark.bubble")
            }

        case .final(let step):
            return doing(step)
        }
    }

    /// 最終 PR の段取り（例: 最終 PR #512 のチェックを待って、レビューしています）
    private static func doing(_ step: FinalStep) -> (String, String) {
        switch step {
        case .verifying:
            return ("最終 PR の前の検証（UI テストを含む）を流しています", "checkmark.shield")

        case .classifying:
            return ("仮決めを、見えるものと内部の細部に仕分けています", "tray.2")

        case .capturing:
            return ("見える仮決めのスクショを撮っています", "camera")

        case .opening:
            return ("最終 PR を出しています", "arrow.up.doc")

        case .reviewing(let pullRequest):
            return ("\(finalLabel(pullRequest)) のチェックを待って、レビューしています", "eye")

        case let .fixing(pullRequest, .checks(round)):
            return ("\(finalLabel(pullRequest)) の CI の失敗を直しています（\(round) 回目）", "wrench.and.screwdriver")

        case let .fixing(pullRequest, .review(round)):
            return ("\(finalLabel(pullRequest)) のレビューの指摘を直しています（\(round) 回目）", "wrench.and.screwdriver")

        case let .fixing(pullRequest, .conflict(round)):
            return ("\(finalLabel(pullRequest)) の base とのコンフリクトを直しています（\(round) 回目）", "wrench.and.screwdriver")

        case .fixing(let pullRequest, .request):
            return ("\(finalLabel(pullRequest)) を頼まれたとおりに直しています", "wrench.and.screwdriver")

        case .merging(let pullRequest):
            return ("\(finalLabel(pullRequest)) をマージしています", "arrow.triangle.merge")
        }
    }

    /// 段取りの名前（例: タスク 2/5「並べ替えのボタン」の実装）
    private static func name(of step: WorkStep, epic: Epic) -> String {
        switch step {
        case .prepareWorkspace:
            return "作業場所の用意"

        case let .task(taskID, phase):
            switch phase {
            case .implementing:
                return "\(taskLabel(taskID, epic: epic))の実装"

            case .reviewing(let pullRequest):
                return "\(pullRequestLabel(taskID, pullRequest, epic: epic)) のレビュー"

            case let .fixing(pullRequest, _, reason):
                return "\(pullRequestLabel(taskID, pullRequest, epic: epic)) の\(spaced(fixLabel(reason)))の直し"

            case .waitingForAnswer(let question, _):
                return "\(taskLabel(taskID, epic: epic))の途中の質問 \(question)"
            }

        case .final(let step):
            return name(of: step)
        }
    }

    /// 最終 PR の段取りの名前（例: 最終 PR #512 のレビュー）
    private static func name(of step: FinalStep) -> String {
        switch step {
        case .verifying: "最終 PR の前の検証"
        case .classifying: "仮決めの仕分け"
        case .capturing: "スクショの撮影"
        case .opening: "最終 PR づくり"
        case .reviewing(let pullRequest): "\(finalLabel(pullRequest)) のレビュー"
        case .fixing(let pullRequest, .checks): "\(finalLabel(pullRequest)) の CI の失敗の直し"
        case .fixing(let pullRequest, .review): "\(finalLabel(pullRequest)) のレビューの指摘の直し"
        case .fixing(let pullRequest, .conflict): "\(finalLabel(pullRequest)) のコンフリクトの直し"
        case .fixing(let pullRequest, .request): "\(finalLabel(pullRequest)) の頼まれた直し"
        case .merging(let pullRequest): "\(finalLabel(pullRequest)) のマージ"
        }
    }

    /// 最終 PR の呼び名（例: 最終 PR #512）
    private static func finalLabel(_ number: Int?) -> String {
        "最終 PR" + (number.map { " #\($0)" } ?? "")
    }

    /// タスクの呼び名。何番目か・全体の数と、題を出す（例: タスク 2/5「並べ替えのボタン」）
    private static func taskLabel(_ taskID: EpicTask.ID, epic: Epic) -> String {
        guard let task = epic.tasks.first(where: { $0.id == taskID }) else {
            return "タスク"
        }
        return "タスク \(task.number)/\(epic.tasks.count)「\(task.title)」"
    }

    /// タスクの子 PR の呼び名。行が長くならないよう、タスクの題は省く（例: タスク 2/5 の子 PR #62）
    private static func pullRequestLabel(_ taskID: EpicTask.ID, _ number: Int?, epic: Epic) -> String {
        let task = epic.tasks.first { $0.id == taskID }.map { "タスク \($0.number)/\(epic.tasks.count) の" } ?? ""
        return task + (number.map { "子 PR #\($0)" } ?? "子 PR")
    }

    /// 日本語の後に英数字で始まる語を続けるときは、間を空ける（例: の CI の失敗）
    private static func spaced(_ word: String) -> String {
        word.first?.isASCII == true ? " \(word)" : word
    }

    static func fixLabel(_ reason: EpicTask.FixReason?) -> String {
        switch reason {
        case .checks: "CI の失敗"
        case .review: "レビューの指摘"
        case nil: "指摘"
        }
    }
}
