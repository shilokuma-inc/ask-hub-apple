import Foundation

// MARK: - 配信した版とリリースを始めた版

extension InboxBuilder {
    /// 配信した版の人の番（司令塔が通知するものと同じ: リリース文の確認と、人が直す後作業）
    static func releaseItems(_ release: Release, snapshot: ClientSnapshot) -> [InboxItem] {
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

    /// リリースを始めた版の人の番（司令塔が通知するものと同じ: 審査に出す・配信する・人が直す準備）と、リジェクトの知らせ
    /// 審査で断られた版の人の番: 理由を貼る（AskHub で出した版）・直し方を選ぶ。手で出した版は App Store Connect で確かめるだけ。
    /// 理由を貼った後、Claude が案を書いている間と、直し方を選んだ後は出さない
    private static func rejectionItems(
        _ submission: Submission,
        rejected: Submission.Review,
        item: (InboxItem.Kind, String, String, String, Date) -> InboxItem
    ) -> [InboxItem] {
        if submission.awaitsRejectionChoice, let rejection = submission.rejection {
            let detail = rejection.triage.map { "\($0.summary)（勧める直し方: \($0.remedy.label)）" }
                ?? "直し方の案を書けませんでした。理由を読んで、直し方を選んでください"
            return [item(.submissionRejected, "rejection-choice", "リジェクトの直し方を選ぶ", detail, rejection.reportedAt)]
        }
        if submission.awaitsRejectionReport {
            let detail = "\(rejected.platform) が審査で断られました。App Store Connect で理由を見て、AskHub に貼ってください。直し方の案を書きます"
            return [item(.submissionRejected, "rejected", "審査で断られました", detail, rejected.since)]
        }
        guard !submission.startedInAskHub else { return [] }
        let detail = "\(rejected.platform) が審査で断られました。App Store Connect で理由を確かめてください"
        return [item(.submissionRejected, "rejected", "審査で断られました", detail, rejected.since)]
    }

    static func submissionItems(_ submission: Submission, snapshot: ClientSnapshot) -> [InboxItem] {
        // 配信した後は、release ブランチの取り込みで人が直す問題だけ出す
        let integrationOnly = submission.end == .distributed
        guard !submission.isEnded || integrationOnly, submission.sending == nil else {
            return abandonedSlotItems(submission, snapshot: snapshot)
        }
        let appName = snapshot.repository(submission.repositoryID)?.appName ?? submission.repositoryID
        let context = "\(appName) · \(submission.version)"
        let route = AppRoute.submission(repositoryID: submission.repositoryID, version: submission.version)
        let targets: [IntentTarget] = [.submission(repositoryID: submission.repositoryID, version: submission.version)]
        func item(_ kind: InboxItem.Kind, _ suffix: String, title: String, detail: String, since: Date) -> InboxItem {
            InboxItem(
                id: "submission/\(submission.id)/\(suffix)",
                urgency: .blocking,
                kind: kind,
                repositoryID: submission.repositoryID,
                title: title,
                context: context,
                detail: detail,
                since: since,
                route: route,
                targets: targets
            )
        }
        var items: [InboxItem] = []
        if integrationOnly {
            guard let problem = submission.problem, problem.step == .integration, problem.needsHuman else { return [] }
            let title = "配信の後作業を直す: \(problem.step.label)"
            return [item(.submissionProblem, "problem", title: title, detail: problem.message, since: problem.at)]
        }
        if submission.awaitsSubmission {
            let detail = submission.rejected.map { "受け付けませんでした: \($0)" }
                ?? "ビルド \(submission.buildSummary) の準備ができました。What's New を確かめて、配信の方式を選んでください"
            items.append(item(.submissionReady, "ready", title: "審査に出す", detail: detail, since: submission.updatedAt))
        }
        if submission.awaitsDistribution {
            let since = submission.review.first { $0.state == .pendingRelease }?.since ?? submission.updatedAt
            let detail = "審査に通りました。配信すると取り消せません"
            items.append(item(.submissionDistribution, "distribute", title: "配信する", detail: detail, since: since))
        }
        if let rejected = submission.review.first(where: { $0.state == .rejected }) {
            items += rejectionItems(submission, rejected: rejected) { item($0, $1, title: $2, detail: $3, since: $4) }
        }
        if let problem = submission.problem, problem.needsHuman {
            let title = "リリースを直す: \(problem.step.label)"
            items.append(item(.submissionProblem, "problem", title: title, detail: problem.message, since: problem.at))
        }
        return items
    }

    /// やめたリリースの、App Store Connect から消せなかった版の枠（人が App Store Connect で確かめる）
    static func abandonedSlotItems(_ submission: Submission, snapshot: ClientSnapshot) -> [InboxItem] {
        let kept = (submission.slots ?? []).filter { $0.keptNote != nil }
        guard submission.end == .abandoned, !kept.isEmpty, submission.sending == nil else { return [] }
        let appName = snapshot.repository(submission.repositoryID)?.appName ?? submission.repositoryID
        let item = InboxItem(
            id: "submission/\(submission.id)/slots",
            urgency: .blocking,
            kind: .submissionProblem,
            repositoryID: submission.repositoryID,
            title: "やめたリリースの版を App Store Connect で確かめる",
            context: "\(appName) · \(submission.version)",
            detail: kept.compactMap { slot in slot.keptNote.map { "\(slot.platform): \($0)" } }.joined(separator: "\n"),
            since: submission.updatedAt,
            route: .submission(repositoryID: submission.repositoryID, version: submission.version),
            targets: [.submission(repositoryID: submission.repositoryID, version: submission.version)]
        )
        return [item]
    }
}

// MARK: - App Store に載せる準備

extension InboxBuilder {
    /// 準備の人の番（司令塔が通知するものと同じ: アプリを作る・初めての版の残り・書けなかった項目・確かめられない）
    static func appStoreSetupItems(_ setup: AppStoreSetup, snapshot: ClientSnapshot) -> [InboxItem] {
        guard setup.isActive, !snapshot.isRemoved(setup.repositoryID) else { return [] }
        let appName = snapshot.repository(setup.repositoryID)?.appName ?? setup.repositoryID
        let firstRelease = snapshot.isFirstRelease(of: setup.repositoryID)
        func item(_ suffix: String, title: String, detail: String, since: Date) -> InboxItem {
            InboxItem(
                id: "appStore/\(setup.repositoryID)/\(suffix)",
                urgency: .blocking,
                kind: .appStoreSetup,
                repositoryID: setup.repositoryID,
                title: title,
                context: "\(appName) · App Store の準備",
                detail: detail,
                since: since,
                route: .appStoreSetup(setup.repositoryID),
                targets: [.appStore(setup.repositoryID)]
            )
        }
        var items: [InboxItem] = []
        let pending = setup.pendingItems(firstRelease: firstRelease)
        if setup.app == nil, !pending.isEmpty {
            let detail = "App Store Connect にアプリがありません。チェックリストを見て作ってください（残り \(pending.count)）"
            items.append(item("app", title: "App Store Connect でアプリを作る", detail: detail, since: setup.updatedAt))
        } else if firstRelease, !pending.isEmpty {
            let detail = "初めての版を審査に出すまでに、" + AppStoreSetup.remainingSummary(pending)
            items.append(item("firstRelease", title: "App Store の準備を終える", detail: detail, since: setup.updatedAt))
        }
        if !setup.isWriting, let failure = setup.failures.first {
            let detail = "\(failure.item.title): \(failure.message)"
            items.append(item("failed", title: "App Store Connect に書けなかった項目を直す", detail: detail, since: setup.updatedAt))
        }
        if let problem = setup.problem, problem.needsHuman {
            items.append(item("problem", title: "App Store の準備を確かめられません", detail: problem.message, since: setup.updatedAt))
        }
        return items
    }
}
