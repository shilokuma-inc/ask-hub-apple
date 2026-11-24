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
            let canCapture = documents.repositories.first { $0.repo == file.repo }?.canCaptureStoreScreenshots ?? false
            var submission = Self.submission(file, canCapture: canCapture)
            let pending = overlaid.filter { Self.targets($0, repo: file.repo, version: file.version) }
            if let envelope = pending.first {
                submission.sending = Self.action(of: envelope.kind)
            } else {
                submission.rejected = rejectedRequest(repo: file.repo, version: file.version)
            }
            index.submissions[submission.id] = Self.entry(file, canCapture: canCapture, idle: pending.isEmpty)
            if !file.isEnded, pending.allSatisfy({ $0.kind != AbandonReleaseIntent.kind }) {
                index.releasingRepositories.insert(submission.repositoryID)
                index.openReleases[submission.repositoryID, default: []].append((file.version, file.hotfix != nil))
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

    /// 操作を送るときに確かめる中身。`idle` は、この端末から送って司令塔がまだ処理していない操作が無いか
    private static func entry(_ file: SubmissionFile, canCapture: Bool, idle: Bool) -> StateIndex.SubmissionEntry {
        StateIndex.SubmissionEntry(
            target: SubmissionTarget(repo: file.repo, version: file.version),
            revision: file.revision,
            builds: file.builds.map { .init(platform: $0.platform, build: $0.build) },
            locales: file.whatsNew?.drafts.map(\.locale) ?? [],
            listing: file.listing?.current ?? [],
            hasAppReview: file.appReview != nil,
            screenshotCommit: file.screenshots?.state == .captured ? file.screenshots?.commit : nil,
            changedShots: Set((file.screenshots?.sets ?? []).flatMap { set in
                set.shots.filter(\.changed).map { Submission.ShotKey(displayType: set.displayType, locale: set.locale, index: $0.index) }
            }),
            canSubmit: file.awaitsSubmission && idle,
            canDistribute: file.awaitsDistribution && idle,
            canWithdraw: file.canWithdraw && idle,
            canAbandon: file.canAbandon && idle,
            canRetakeScreenshots: file.retakeProblem(canCapture: canCapture) == nil && idle,
            canReportRejection: file.canReportRejection && idle,
            canResolveRejection: file.awaitsRejectionChoice && idle
        )
    }

    /// `canCapture` は、リポジトリで App Store のスクショを撮れるか（撮らなかった版を後から撮れるか）
    static func submission(_ file: SubmissionFile, canCapture: Bool) -> Submission {
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
            listing: file.listing.map(listing),
            appReview: file.appReview.map { review in
                Submission.AppReview(current: reviewInfo(review.current), draft: review.draft.map(reviewInfo), reason: review.reason)
            },
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
        submission.branchCreatedAt = file.branch?.at.date
        submission.hotfixFrom = file.hotfix?.from.rawValue
        submission.suspendedBy = file.isSuspended ? file.suspension?.by.rawValue : nil
        submission.submitted = file.submit.map(submitted)
        submission.slots = file.appStoreVersions.map { $0.map(slot) }
        submission.screenshots = file.screenshots.map(storeScreenshots)
        submission.awaitsSubmission = file.awaitsSubmission
        submission.awaitsDistribution = file.awaitsDistribution
        submission.canWithdraw = file.canWithdraw
        submission.canAbandon = file.canAbandon
        submission.canRetakeScreenshots = file.retakeProblem(canCapture: canCapture) == nil
        submission.isSubmitting = file.isSubmitting
        submission.rejection = file.rejection.map(rejection)
        submission.awaitsRejectionReport = file.awaitsRejectionReport
        submission.canReportRejection = file.canReportRejection
        submission.awaitsRejectionChoice = file.awaitsRejectionChoice
        submission.awaitsFixedBuild = file.awaitsFixedBuild
        return submission
    }

    /// リジェクトの対処。画像は、貼った端末の鍵と意図の nonce で決まる状態リポジトリのパスで読む
    static func rejection(_ rejection: SubmissionFile.Rejection) -> Submission.Rejection {
        let report = rejection.report
        return Submission.Rejection(
            platforms: rejection.platforms.map(\.rawValue),
            text: report.text,
            images: report.attachments.map { attachment in
                let path = StatePath.attachment(device: report.approval.keyId, nonce: report.approval.nonce, number: attachment.number)
                return Submission.RejectionImage(path: path, name: attachment.name)
            },
            reportedAt: report.at.date,
            triage: rejection.triage.map { triage in
                Submission.RejectionTriage(
                    remedy: Submission.Remedy(rawValue: triage.remedy.rawValue) ?? .code,
                    summary: triage.summary,
                    plan: triage.plan,
                    requestTitle: triage.request?.title,
                    requestBody: triage.request?.body,
                    reply: triage.reply,
                    metadataChanges: metadataChanges(triage)
                )
            },
            failure: rejection.failure,
            choice: rejection.choice.flatMap { Submission.Remedy(rawValue: $0.remedy.rawValue) }
        )
    }

    /// メタデータを直す案のある欄（例: 説明文（ja））
    private static func metadataChanges(_ triage: SubmissionFile.RejectionTriage) -> [String] {
        var changes: [String] = []
        for draft in triage.listing?.drafts ?? [] {
            for field in ListingText.Field.allCases where draft[field] != nil {
                let name = switch field {
                case .description: "説明文"
                case .keywords: "キーワード"
                case .promotionalText: "プロモーションテキスト"
                }
                changes.append("\(name)（\(draft.locale)）")
            }
        }
        changes += (triage.whatsNew ?? []).map { "What's New（\($0.locale)）" }
        if triage.appReview?.draft != nil { changes.append("App Review の情報") }
        return changes
    }

    /// 人が審査に出した中身
    private static func submitted(_ submit: SubmissionFile.Submit) -> Submission.Submitted {
        Submission.Submitted(
            builds: submit.builds.map { Submission.Build(platform: $0.platform.rawValue, build: $0.build) },
            whatsNew: submit.whatsNew.map { Submission.Localized(locale: $0.locale, text: $0.text) },
            releaseType: releaseType(submit.releaseType, date: submit.earliestReleaseDate),
            at: submit.at.date,
            listing: (submit.listing ?? []).map(listingTexts),
            appReview: submit.appReview.map(reviewInfo)
        )
    }

    private static func storeScreenshots(_ file: SubmissionFile.StoreScreenshots) -> Submission.StoreScreenshots {
        let state: Submission.ScreenshotState = switch file.state {
        case .capturing: .capturing
        case .captured: .captured
        case .failed: .failed(file.failure ?? "理由は書かれていません")
        case .notConfigured: .notConfigured
        }
        let sets = file.sets.map { set in
            Submission.ScreenshotSet(
                displayType: set.displayType,
                locale: set.locale,
                shots: set.shots.map { shot in
                    Submission.Shot(
                        index: shot.index,
                        name: shot.name,
                        changed: shot.changed,
                        before: shot.before.flatMap(URL.init(string:)).map(Screenshot.remote),
                        after: shot.preview.map(Screenshot.stored),
                        area: shot.area.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) },
                        rejected: shot.rejected
                    )
                },
                removed: set.removed
            )
        }
        let skipped = file.skipped.map { Submission.SkippedDisplayType(displayType: $0.displayType, reason: $0.reason) }
        return Submission.StoreScreenshots(state: state, commit: file.commit, sets: sets, skipped: skipped, progress: progress(of: file))
    }

    /// 撮っている間の今の段階。App Store Connect の取り込みを待っているか、GitHub Actions で撮っているか。UI テストの撮り方は nil
    static func progress(of file: SubmissionFile.StoreScreenshots) -> String? {
        guard file.state == .capturing else { return nil }
        if let library = file.library {
            return "App Store Connect の取り込みを待っています（\(library.ready) / \(library.total) 枚）"
        }
        guard let run = file.run else { return nil }
        return switch run.status {
        case "completed": "撮った画像を取り込んで、前回の App Store のものと比べています"
        case "in_progress": "GitHub Actions で撮っています"
        default: "GitHub Actions の撮影を待っています"
        }
    }

    private static func slot(_ slot: SubmissionFile.VersionSlot) -> Submission.Slot {
        Submission.Slot(platform: slot.platform.rawValue, build: slot.build, keptNote: slot.removal == .kept ? slot.removalNote : nil)
    }

    private static func listing(_ listing: SubmissionFile.Listing) -> Submission.Listing {
        Submission.Listing(current: listing.current.map(listingTexts), drafts: listing.drafts.map(listingTexts), reason: listing.reason)
    }

    private static func reviewInfo(_ information: ReviewInformation) -> Submission.ReviewInfo {
        Submission.ReviewInfo(
            notes: information.notes, demoAccountRequired: information.demoAccountRequired, demoAccountName: information.demoAccountName
        )
    }

    static func listingTexts(_ text: ListingText) -> Submission.ListingTexts {
        var values: [Submission.ListingField: String] = [:]
        for field in Submission.ListingField.allCases {
            if let value = text[listingField(field)] { values[field] = value }
        }
        return Submission.ListingTexts(locale: text.locale, values: values)
    }

    /// 画面の掲載文の欄に当たる、プロトコルの欄
    static func listingField(_ field: Submission.ListingField) -> ListingText.Field {
        switch field {
        case .description: .description
        case .keywords: .keywords
        case .promotionalText: .promotionalText
        }
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
        case RetakeScreenshotsIntent.kind: .retake
        case ReportRejectionIntent.kind: .reportRejection
        case ResolveRejectionIntent.kind: .resolveRejection
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
