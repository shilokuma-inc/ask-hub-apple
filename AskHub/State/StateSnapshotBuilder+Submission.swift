import AskHubProtocol
import Foundation

// MARK: - リリースを始めた版

extension StateSnapshotBuilder {
    /// リリースを始めた版（リポジトリの順、その中は新しい版から）。この端末が送って司令塔がまだ処理していない操作は、送った結果として先に出し、
    /// 断られた操作は理由を出す。まだ記録の無い「リリースを始める」は、始めている版として出す
    func submissions(index: inout StateIndex, overlaid: [IntentEnvelope]) -> [Submission] {
        for release in documents.releases {
            let id = Self.repository(release.repo).id
            index.releasedVersions[id] = max(index.releasedVersions[id] ?? release.version, release.version)
        }
        var submissions: [Submission] = []
        for file in documents.submissions {
            var submission = Self.submission(file)
            let pending = overlaid.filter { Self.targets($0, repo: file.repo, version: file.version) }
            if let envelope = pending.first {
                submission.sending = Self.action(of: envelope.kind)
            } else {
                submission.rejected = rejectedRequest(repo: file.repo, version: file.version)
            }
            index.submissions[submission.id] = StateIndex.SubmissionEntry(
                target: SubmissionTarget(repo: file.repo, version: file.version),
                revision: file.revision,
                builds: file.builds.map { .init(platform: $0.platform, build: $0.build) },
                locales: file.whatsNew?.drafts.map(\.locale) ?? [],
                canSubmit: file.awaitsSubmission && pending.isEmpty,
                canDistribute: file.awaitsDistribution && pending.isEmpty,
                canWithdraw: file.canWithdraw && pending.isEmpty,
                canAbandon: file.canAbandon && pending.isEmpty
            )
            if !file.isEnded, pending.allSatisfy({ $0.kind != AbandonReleaseIntent.kind }) {
                index.releasingRepositories.insert(submission.repositoryID)
            }
            submissions.append(submission)
        }
        // まだ記録の無い「リリースを始める」（送った・司令塔が受け付けて記録を作る前）
        for envelope in overlaid where envelope.kind == StartReleaseIntent.kind {
            guard let start = try? StartReleaseIntent(envelope: envelope),
                  !documents.submissions.contains(where: { $0.repo == start.repo && $0.version == start.version && !$0.isEnded }) else {
                continue
            }
            let repositoryID = Self.repository(start.repo).id
            index.releasingRepositories.insert(repositoryID)
            submissions.removeAll { $0.repositoryID == repositoryID && $0.version == start.version.rawValue }
            submissions.append(Submission(
                repositoryID: repositoryID,
                version: start.version.rawValue,
                startedInAskHub: true,
                revision: 0,
                createdAt: envelope.issuedAt.date,
                updatedAt: envelope.issuedAt.date,
                sending: .start
            ))
        }
        return submissions.sorted { lhs, rhs in
            lhs.repositoryID == rhs.repositoryID ? ClientSnapshot.isOlder(rhs.version, lhs.version)
                : lhs.repositoryID.localizedStandardCompare(rhs.repositoryID) == .orderedAscending
        }
    }

    static func submission(_ file: SubmissionFile) -> Submission {
        var submission = Submission(
            repositoryID: repository(file.repo).id,
            version: file.version.rawValue,
            startedInAskHub: file.origin == .askhub,
            branch: file.branch?.name,
            nextVersion: file.nextVersion.map { next in
                Release.NextVersion(version: next.version.rawValue, state: nextVersionState(next.state), pullRequest: next.pullRequest)
            },
            builds: file.builds.map { Submission.Build(platform: $0.platform.rawValue, build: $0.build) },
            drafts: file.whatsNew.map { $0.drafts.map { Submission.Localized(locale: $0.locale, text: $0.text) } },
            revision: file.revision,
            review: file.review.map { review in
                Submission.Review(platform: review.platform.rawValue, state: reviewState(review.state), since: review.since.date)
            },
            distribution: requestState(file.distribution),
            withdrawal: requestState(file.withdrawal),
            end: file.end.map { endReason($0.reason) },
            problem: file.problem.map { problem in
                Submission.Problem(
                    step: Submission.Step(rawValue: problem.step.rawValue) ?? .review,
                    message: problem.message,
                    needsHuman: problem.needsHuman,
                    at: problem.at.date
                )
            },
            createdAt: file.createdAt.date,
            updatedAt: file.updatedAt.date
        )
        submission.submitted = file.submit.map { submit in
            Submission.Submitted(
                builds: submit.builds.map { Submission.Build(platform: $0.platform.rawValue, build: $0.build) },
                whatsNew: submit.whatsNew.map { Submission.Localized(locale: $0.locale, text: $0.text) },
                releaseType: releaseType(submit.releaseType, date: submit.earliestReleaseDate),
                at: submit.at.date
            )
        }
        submission.slots = file.appStoreVersions.map { slots in
            slots.map { slot in
                let keptNote = slot.removal == .kept ? slot.removalNote : nil
                return Submission.Slot(platform: slot.platform.rawValue, build: slot.build, keptNote: keptNote)
            }
        }
        submission.awaitsSubmission = file.awaitsSubmission
        submission.awaitsDistribution = file.awaitsDistribution
        submission.canWithdraw = file.canWithdraw
        submission.canAbandon = file.canAbandon
        submission.isSubmitting = file.isSubmitting
        return submission
    }

    /// その版への、リリースの操作の意図か
    private static func targets(_ envelope: IntentEnvelope, repo: RepositoryFullName, version: MarketingVersion) -> Bool {
        guard action(of: envelope.kind) != nil, let target = target(of: envelope),
              case let .submission(repositoryID, targetVersion) = target else { return false }
        return repositoryID == repository(repo).id && targetVersion == version.rawValue
    }

    /// その版への操作を、司令塔が最後に断った理由。断られていなければ（後で受け付けた・送っていない）nil
    private func rejectedRequest(repo: RepositoryFullName, version: MarketingVersion) -> String? {
        let latest = documents.sentIntents.first { Self.targets($0.envelope, repo: repo, version: version) }
        guard let consumed = latest?.consumed, consumed.result == .rejected else { return nil }
        return consumed.reason ?? "理由は書かれていません"
    }

    static func action(of kind: String) -> Submission.Action? {
        switch kind {
        case StartReleaseIntent.kind: .start
        case SubmitForReviewIntent.kind: .submit
        case DistributeReleaseIntent.kind: .distribute
        case WithdrawSubmissionIntent.kind: .withdraw
        case AbandonReleaseIntent.kind: .abandon
        default: nil
        }
    }

    private static func reviewState(_ state: AppStoreVersionState) -> Submission.ReviewState {
        switch state {
        case .prepareForSubmission, .readyForReview: .preparing
        case .waitingForReview, .waitingForExportCompliance: .waitingForReview
        case .inReview: .inReview
        case .pendingDeveloperRelease: .pendingRelease
        case .pendingAppleRelease, .processingForDistribution, .accepted: .approved
        case .readyForDistribution, .replacedWithNewVersion: .distributed
        case .rejected, .metadataRejected, .invalidBinary: .rejected
        case .developerRejected: .withdrawn
        }
    }

    private static func requestState(_ request: SubmissionFile.Request?) -> Submission.RequestState {
        guard let request else { return .none }
        return request.doneAt == nil ? .accepted : .done
    }

    private static func endReason(_ reason: SubmissionFile.EndReason) -> Submission.EndReason {
        switch reason {
        case .distributed: .distributed
        case .abandoned: .abandoned
        case .superseded: .superseded
        }
    }

    private static func releaseType(_ type: AppStoreReleaseType, date: Timestamp?) -> Submission.ReleaseType {
        switch type {
        case .afterApproval: .afterApproval
        case .manual: .manual
        case .scheduled: .scheduled(date?.date ?? .distantFuture)
        }
    }

    private static func nextVersionState(_ state: ReleaseFile.NextVersionState) -> Release.NextVersionState {
        switch state {
        case .open: .open
        case .merged: .merged
        case .skipped: .skipped
        }
    }
}
