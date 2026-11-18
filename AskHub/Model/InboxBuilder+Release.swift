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
    static func submissionItems(_ submission: Submission, snapshot: ClientSnapshot) -> [InboxItem] {
        guard !submission.isEnded, submission.sending == nil else { return [] }
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
            let detail = "\(rejected.platform) が審査で断られました。App Store Connect で理由を確かめてください"
            items.append(item(.submissionRejected, "rejected", title: "審査で断られました", detail: detail, since: rejected.since))
        }
        if let problem = submission.problem, problem.needsHuman {
            let title = "リリースを直す: \(problem.step.label)"
            items.append(item(.submissionProblem, "problem", title: title, detail: problem.message, since: problem.at))
        }
        return items
    }
}
