import Foundation

/// epic の「いま」の 1 行。人が待たれているのか、機械が進めているのかを分けて出す
struct EpicStatusLine: Hashable {
    var owner: Owner
    var text: String
    var systemImage: String
    /// 押したときに開く画面
    var route: AppRoute?

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
        return humanLines(epic) + epic.activities.map { machineLine($0, epic: epic, snapshot: snapshot, now: now) }
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
        let answerable = epic.answerableQuestions.count
        if epic.stage == .questions, answerable > 0 {
            lines.append(you("あなたの回答を待っています（\(answerable) 問）", "questionmark.bubble.fill", route: .deck(.questions(epic.id))))
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
        let macName = snapshot.mac(epic.macID)?.name ?? "Mac"
        let (text, symbol) = describe(activity.kind, epic: epic, macName: macName, snapshot: snapshot, now: now)
        return EpicStatusLine(owner: .machine, text: text, systemImage: symbol, route: nil)
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
        case let .implementing(taskID, attempt):
            let task = epic.tasks.first { $0.id == taskID }
            let title = task.map { "タスク \($0.number)「\($0.title)」" } ?? "タスク"
            return ("\(macName) で\(title)を実装しています\(attempt > 1 ? "（試行 \(attempt)）" : "")", "hammer")

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
}
