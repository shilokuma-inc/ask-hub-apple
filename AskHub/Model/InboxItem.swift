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
    /// この出番で働きかける対象（送った操作が反映を待っていれば、行に印を出す）
    var targets: [IntentTarget] = []

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
        /// 1 つの epic に収まらないと分かり、分け方の判断を待っている
        case split
        case humanTask
        case blocker
        case macOffline
        /// トークンの期限が近い・切れた（入れ直す）
        case token
        /// Claude Code の版が Mac の間でそろっていない
        case claudeVersion
        /// ワーカーの互換の番号が司令塔と合わず、新しいジョブを引き受けていない（更新する）
        case compatibility
        case finalReview
        case verification
        case cleanup
        /// App Store で配信した版のリリース文を確かめて、公開する
        case releaseNotes
        /// 配信した版の後作業が、人が直すまで進まない
        case releaseProblem
    }
}

/// 状態から「あなたの番」を組み立てる
enum InboxBuilder {
    /// ジョブを持った Mac がこれより長くオフラインなら知らせる（閉じるたびには知らせない）
    static let offlineNoticeDelay: TimeInterval = 30 * 60
    /// トークンの期限は、これより長くオフラインの Mac では知らせない（使わなくなった Mac で知らせ続けない）。
    /// 状態リポジトリのトークンが切れた Mac は印を書けずにオフラインになるので、オフラインになってもしばらくは知らせる
    static let tokenNoticeWindow: TimeInterval = 7 * 24 * 60 * 60

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
        items += snapshot.macs.flatMap { tokenItems($0, now: now) }
        items += snapshot.macs.compactMap(claudeVersionItem)
        items += snapshot.macs.compactMap(compatibilityItem)
        items += snapshot.macs.compactMap(cleanupItem)
        items += snapshot.releases.flatMap { releaseItems($0, snapshot: snapshot) }
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
        if let split = epic.split, split.choice == nil {
            var item = InboxItem(epic: epic, kind: .split, context: context, route: .epic(epic.id))
            item.title = "分け方を決める"
            item.detail = split.reason
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
        let answerable = epic.awaitedQuestions
        guard !answerable.isEmpty else {
            return revisingItem(epic, context: context)
        }
        // 実装の途中の質問は、答えるまで epic が止まっていることと、どこで出たかを出す
        if let point = answerable.first?.during {
            var item = InboxItem(epic: epic, kind: .questions, context: context, route: .deck(.questions(epic.id)))
            item.title = "実装の途中の質問に答える"
            item.detail = "\(point.label)の途中です。答えるまで止めて待っています"
            item.since = answerable.map(\.askedAt).max() ?? epic.updatedAt
            return item
        }
        var parts = ["残り \(answerable.count) 問"]
        let explaining = epic.questions.filter(\.isAwaitingExplanation).count
        if explaining > 0 {
            parts.append("説明待ち \(explaining)")
        }
        let revising = epic.questions.filter { $0.state == .reviewing }.count
        if revising > 0 {
            parts.append("見直し中 \(revising)")
        }
        let locked = epic.questions.filter { $0.state == .locked }.count
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
        item.detail = "\(VerificationItem.buildLabel(build)) · \(ready.count) 項目"
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

    /// 期限まで 14 日を切ったトークン（入れ直す）と、期限が切れた・使えないトークン（止まっている）
    private static func tokenItems(_ mac: Mac, now: Date) -> [InboxItem] {
        let lastSeen: Date
        switch mac.connection {
        case .online(let date), .offline(let date):
            lastSeen = date
        }
        guard now.timeIntervalSince(lastSeen) < tokenNoticeWindow else {
            return []
        }
        return mac.tokens.compactMap { token in
            let title: String
            let detail: String
            var since = lastSeen
            switch token.status(now: now) {
            case .ok:
                return nil
            case .expiringSoon(let days):
                title = "トークンを入れ直す"
                detail = "\(token.name)があと \(days) 日で切れます"
                since = token.expiresAt.map { $0.addingTimeInterval(-MacToken.renewalNotice) } ?? lastSeen
            case .stopped(let state) where !token.stopsWork:
                // 管理用のトークンは、管理の操作を断るだけで仕事は止めないので、時間のあるときに入れ直してもらう
                title = "管理用のトークンを入れ直す"
                detail = "\(token.name)が\(state == .expired ? "切れました" : "使えません")。保護の設定と対象に加えるときの準備を断ります"
                since = token.expiresAt.map { min($0, lastSeen) } ?? lastSeen
            case .stopped(let state):
                title = state == .expired ? "トークンの期限が切れて止まっています" : "トークンが使えず止まっています"
                detail = token.name
                since = token.expiresAt.map { min($0, lastSeen) } ?? lastSeen
            }
            return InboxItem(
                id: "mac/\(mac.id)/token/\(token.id)",
                urgency: token.isStopped(now: now) ? .blocking : .whenFree,
                kind: .token,
                repositoryID: nil,
                title: title,
                context: mac.name,
                detail: "\(detail) · \(mac.renewalCommand(for: token))",
                since: since,
                route: .mac(mac.id)
            )
        }
    }

    /// Claude Code の版が司令塔と違う Mac（オンラインのものだけ。オフラインの Mac は戻ってから入れ替える）
    private static func claudeVersionItem(_ mac: Mac) -> InboxItem? {
        guard case .online(let lastSeen) = mac.connection, let version = mac.claudeVersion,
              let commander = mac.commanderClaudeVersion else {
            return nil
        }
        return InboxItem(
            id: "mac/\(mac.id)/claude-version",
            urgency: .whenFree,
            kind: .claudeVersion,
            repositoryID: nil,
            title: "Claude Code の版をそろえる",
            context: mac.name,
            detail: "この Mac は \(version)、司令塔は \(commander)",
            since: lastSeen,
            route: .mac(mac.id)
        )
    }

    /// 互換の番号が司令塔と合わず、新しいジョブを引き受けていない Mac（オンラインのものだけ）。版が違うだけなら出さない。
    /// 番号を比べられない（ワーカーが司令塔の印を読めない）ときは、合わないとは言わず、ワーカーが書いた理由を出す
    private static func compatibilityItem(_ mac: Mac) -> InboxItem? {
        guard case .online(let lastSeen) = mac.connection, let incompatibility = mac.incompatibility else {
            return nil
        }
        let detail = mac.updateCommand.map { "互換の番号が合いません（\(mac.compatibilityText)） · \($0)" }
            ?? "\(mac.compatibilityText) · \(incompatibility.message ?? mac.updateStep)"
        return InboxItem(
            id: "mac/\(mac.id)/compatibility",
            urgency: .blocking,
            kind: .compatibility,
            repositoryID: nil,
            title: mac.updateTitle,
            context: mac.name,
            detail: detail,
            since: lastSeen,
            route: .mac(mac.id)
        )
    }

    /// 配信した版の人の番（司令塔が通知するものと同じ: リリース文の確認と、人が直す後作業）
    private static func releaseItems(_ release: Release, snapshot: ClientSnapshot) -> [InboxItem] {
        let appName = snapshot.repository(release.repositoryID)?.appName ?? release.repositoryID
        let context = "\(appName) · \(release.version)"
        let route = AppRoute.release(repositoryID: release.repositoryID, version: release.version)
        let targets: [IntentTarget] = [.release(repositoryID: release.repositoryID, version: release.version)]
        var items: [InboxItem] = []
        if release.awaitsNotesReview {
            let detail: String = if case .rejected(let reason) = release.publish {
                "公開を受け付けませんでした: \(reason)"
            } else {
                "App Store で配信しました。GitHub Release に載せる文を確かめてください"
            }
            items.append(InboxItem(
                id: "release/\(release.id)/notes",
                urgency: .blocking,
                kind: .releaseNotes,
                repositoryID: release.repositoryID,
                title: "リリース文を確かめて公開する",
                context: context,
                detail: detail,
                since: release.updatedAt,
                route: route,
                targets: targets
            ))
        }
        if let problem = release.problem, problem.needsHuman {
            items.append(InboxItem(
                id: "release/\(release.id)/problem",
                urgency: .blocking,
                kind: .releaseProblem,
                repositoryID: release.repositoryID,
                title: "配信の後作業を直す: \(problem.step.label)",
                context: context,
                detail: problem.message,
                since: problem.at,
                route: route,
                targets: targets
            ))
        }
        return items
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
            route: .cleanup(mac.id),
            targets: [.cleanup(macID: mac.id)]
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
            route: route,
            targets: Self.targets(of: kind, in: epic, route: route)
        )
    }

    /// epic の出番で働きかける対象
    private static func targets(of kind: Kind, in epic: Epic, route: AppRoute) -> [IntentTarget] {
        switch kind {
        case .questions:
            return epic.questions.map { .question(epicID: epic.id, questionID: $0.id) }

        case .goal:
            return [.goal(epicID: epic.id)]

        case .split:
            return [.split(epicID: epic.id)]

        case .humanTask:
            guard case let .humanTask(epicID, taskID) = route else {
                return []
            }
            return [.humanTask(epicID: epicID, taskID: taskID)]

        case .blocker:
            return [.blocker(epicID: epic.id), .epicControl(epicID: epic.id)]

        case .finalReview:
            let decisions = epic.finalReview?.decisions.map { IntentTarget.decision(epicID: epic.id, decisionID: $0.id) } ?? []
            return [.finalPullRequest(epicID: epic.id)] + decisions

        case .verification:
            return epic.finalReview?.verifications.map { .verification(epicID: epic.id, itemID: $0.id) } ?? []

        case .macOffline, .token, .claudeVersion, .compatibility, .cleanup, .releaseNotes, .releaseProblem:
            return []
        }
    }
}

/// 容量の表示（例: 48 GB）
enum ByteFormat {
    /// バイト数を、KB から TB までの単位の文字にする（0 は「0 KB」）
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // 既定では 0 を「Zero KB」と英語で出すので、数字で出す（片付けで何も選んでいないとき）。
        // バイトの単位も「bytes」と英語になるので、KB から使う
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - 見直し中の質問

extension InboxBuilder {
    /// 答えられる質問は残っていないが、Claude が見直している質問があるとき。答えた質問の行が消えて、質問が無くなったように見えないよう、
    /// 見直しが終わるまで出しておく（人の出番ではないので、時間のあるときに）
    private static func revisingItem(_ epic: Epic, context: String) -> InboxItem? {
        let revising = epic.questions.filter { $0.state == .reviewing }
        guard epic.stage == .questions, !revising.isEmpty else {
            return nil
        }
        var item = InboxItem(epic: epic, kind: .questions, context: context, route: .epic(epic.id))
        item.urgency = .whenFree
        item.title = "質問の見直しを待っています"
        item.detail = "Claude が \(revising.map(\.id).joined(separator: "・")) を見直しています。終わったら答えられます"
        return item
    }
}
