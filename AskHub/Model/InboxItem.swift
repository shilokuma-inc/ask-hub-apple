import Foundation

/// 「あなたの番」の 1 行。人の出番を、種類をまたいで 1 つの一覧にする
struct InboxItem: Identifiable, Hashable {
    var id: String
    var urgency: Urgency
    var kind: Kind
    var repositoryID: TargetRepository.ID?
    /// 何をするか（例: 質問に答える）
    var title: String
    /// どのアプリのどの epic か
    var context: String
    var detail: String
    var since: Date
    var route: AppRoute

    /// 区分は通知の頻度と同じにする
    enum Urgency: Hashable {
        /// 進行が止まっている（すぐ通知）
        case blocking
        /// 進行は止めない（まとめて通知）
        case whenFree
    }

    enum Kind: Hashable {
        case questions
        case goal
        case humanTask
        case blocker
        case macOffline
        case finalReview
        case verification
        case cleanup
    }
}

/// 状態から「あなたの番」を組み立てる
enum InboxBuilder {
    /// ジョブを持った Mac がこれより長くオフラインなら知らせる（閉じるたびには知らせない）
    static let offlineNoticeDelay: TimeInterval = 30 * 60

    static func items(from snapshot: ClientSnapshot, now: Date) -> [InboxItem] {
        var items: [InboxItem] = []
        for epic in snapshot.epics {
            let appName = snapshot.repository(epic.repositoryID)?.appName ?? epic.repositoryID
            let context = "\(appName) · \(epic.title)"
            if epic.isActive {
                items += epicItems(epic, context: context)
            }
            items += verificationItems(epic, context: context)
        }
        items += snapshot.macs.compactMap { offlineItem($0, now: now) }
        items += snapshot.macs.compactMap(cleanupItem)
        return items.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency {
                return lhs.urgency == .blocking
            }
            return lhs.since > rhs.since
        }
    }

    static func blockingCount(in snapshot: ClientSnapshot, now: Date) -> Int {
        items(from: snapshot, now: now).filter { $0.urgency == .blocking }.count
    }

    private static func epicItems(_ epic: Epic, context: String) -> [InboxItem] {
        var items: [InboxItem] = []
        if let item = questionItem(epic, context: context) {
            items.append(item)
        }
        if epic.stage == .goal, let goal = epic.goal, !goal.isRevising {
            var item = InboxItem(epic: epic, kind: .goal, context: context, route: .goal(epic.id))
            item.title = "ゴールを確かめて開始する"
            item.detail = "タスク \(goal.tasks.count) · 人がする作業 \(epic.humanTasks.count)"
            items.append(item)
        }
        for task in epic.humanTasks where task.needsHuman {
            items.append(humanTaskItem(task, epic: epic, context: context))
        }
        if let blocker = epic.blocker {
            var item = InboxItem(epic: epic, kind: .blocker, context: context, route: .epic(epic.id))
            item.title = "対処する: \(blocker.title)"
            item.detail = blocker.summary
            item.since = blocker.occurredAt
            items.append(item)
        }
        if let item = finalReviewItem(epic, context: context) {
            items.append(item)
        }
        return items
    }

    private static func questionItem(_ epic: Epic, context: String) -> InboxItem? {
        let answerable = epic.answerableQuestions
        guard epic.stage == .questions, !answerable.isEmpty else {
            return nil
        }
        var parts = ["残り \(answerable.count) 問"]
        let explaining = epic.questions.filter(\.isAwaitingExplanation).count
        if explaining > 0 {
            parts.append("説明待ち \(explaining)")
        }
        let locked = epic.questions.filter { $0.state == .locked || $0.state == .reviewing }.count
        if locked > 0 {
            parts.append("ロック \(locked)")
        }
        var item = InboxItem(epic: epic, kind: .questions, context: context, route: .deck(.questions(epic.id)))
        item.title = "質問に答える"
        item.detail = parts.joined(separator: " · ")
        item.since = answerable.map(\.askedAt).max() ?? epic.updatedAt
        return item
    }

    private static func humanTaskItem(_ task: HumanTask, epic: Epic, context: String) -> InboxItem {
        var item = InboxItem(epic: epic, kind: .humanTask, context: context, route: .humanTask(epicID: epic.id, taskID: task.id))
        item.id = "\(epic.id)/human/\(task.id)"
        item.title = "人がする作業: \(task.title)"
        if case .verificationFailed(let reason) = task.state {
            item.detail = "確かめられませんでした: \(reason)"
        } else {
            let blocked = epic.tasks.filter { task.blocksTaskIDs.contains($0.id) }.map { "タスク \($0.number)" }
            item.detail = blocked.isEmpty ? task.why : "\(blocked.joined(separator: "・")) の前提。ほかは進めています"
        }
        return item
    }

    private static func finalReviewItem(_ epic: Epic, context: String) -> InboxItem? {
        guard epic.stage == .finalReview, let review = epic.finalReview, review.state == .reviewable,
              review.mergePolicy != .automatic || review.headChangedAfterReview else {
            return nil
        }
        var parts: [String] = []
        let pending = review.pendingDecisions.count
        if review.headChangedAfterReview {
            parts.append("確かめた後に変更が入りました")
        } else if pending > 0 {
            parts.append("判断 \(pending) 件が未確認")
        } else if review.canMerge {
            parts.append("すべて確かめました。マージできます")
        }
        if review.checks.ci != .passed {
            parts.append("CI を待っています")
        }
        var item = InboxItem(epic: epic, kind: .finalReview, context: context, route: .finalReview(epic.id))
        item.urgency = .whenFree
        item.title = "マージを確かめる"
        item.detail = parts.joined(separator: " · ")
        return item
    }

    private static func verificationItems(_ epic: Epic, context: String) -> [InboxItem] {
        let ready = epic.finalReview?.verifications.filter(\.isReady) ?? []
        guard let first = ready.first, case .ready(let build) = first.state else {
            return []
        }
        var item = InboxItem(epic: epic, kind: .verification, context: context, route: .deck(.verifications(epic.id)))
        item.urgency = .whenFree
        item.title = "実機で確かめる"
        item.detail = "TestFlight \(build) · \(ready.count) 項目"
        return [item]
    }

    private static func offlineItem(_ mac: Mac, now: Date) -> InboxItem? {
        guard case .offline(let since) = mac.connection, let job = mac.jobs.first,
              now.timeIntervalSince(since) >= offlineNoticeDelay else {
            return nil
        }
        return InboxItem(
            id: "mac/\(mac.id)/offline",
            urgency: .blocking,
            kind: .macOffline,
            repositoryID: nil,
            title: "Mac がオフラインです",
            context: mac.name,
            detail: "「\(job.title)」を持ったまま止まっています",
            since: since,
            route: .mac(mac.id)
        )
    }

    private static func cleanupItem(_ mac: Mac) -> InboxItem? {
        guard !mac.cleanupCandidates.isEmpty else {
            return nil
        }
        let bytes = mac.cleanupCandidates.reduce(Int64(0)) { $0 + $1.bytes }
        let lastSeen: Date
        switch mac.connection {
        case .online(let date), .offline(let date):
            lastSeen = date
        }
        return InboxItem(
            id: "mac/\(mac.id)/cleanup",
            urgency: .whenFree,
            kind: .cleanup,
            repositoryID: nil,
            title: "片付けの候補",
            context: mac.name,
            detail: "\(mac.cleanupCandidates.count) 件 · \(ByteFormat.string(bytes))",
            since: lastSeen,
            route: .cleanup(mac.id)
        )
    }
}

extension InboxItem {
    /// epic の項目の雛形。見出しと詳細は呼び出し元で入れる
    init(epic: Epic, kind: Kind, context: String, route: AppRoute) {
        self.init(
            id: "\(epic.id)/\(kind)",
            urgency: .blocking,
            kind: kind,
            repositoryID: epic.repositoryID,
            title: "",
            context: context,
            detail: "",
            since: epic.updatedAt,
            route: route
        )
    }
}

/// 容量の表示（例: 48 GB）
enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
