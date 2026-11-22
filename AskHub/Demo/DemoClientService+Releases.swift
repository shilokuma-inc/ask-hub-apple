import Foundation

// MARK: - 人の意図を当てる（配信した版）

extension DemoClientService {
    /// リリース文の公開。司令塔が受け付けて本文を記録に写し、次の見回りで GitHub Release を公開するのをまねる。
    /// プロモーションテキストは、受け付けて App Store Connect に書くのをまねる
    func applyReleaseIntent(_ intent: HumanIntent) {
        if case let .updatePromotionalText(repositoryID, version, texts) = intent {
            updatePromotionalText(Release.id(repositoryID, version), texts: texts)
            return
        }
        guard case let .publishRelease(repositoryID, version, _, notes) = intent else {
            return
        }
        let id = Release.id(repositoryID, version)
        state.updateRelease(id) { $0.publish = .sending }
        schedule { snapshot in
            snapshot.updateRelease(id) { release in
                release.publish = .none
                release.notes?.confirmed = notes
            }
        }
        schedule(after: 2) { snapshot in
            snapshot.updateRelease(id) { release in
                release.githubReleaseURL = URL(string: "https://github.com/\(repositoryID)/releases/tag/v\(version)")
            }
        }
    }
}

extension DemoClientService {
    private func updatePromotionalText(_ id: Release.ID, texts: [Submission.Localized]) {
        state.updateRelease(id) { $0.promotionalText?.request = .sending }
        schedule { snapshot in
            snapshot.updateRelease(id) { $0.promotionalText?.request = .writing }
        }
        schedule(after: 2) { snapshot in
            snapshot.updateRelease(id) { release in
                for text in texts {
                    guard let index = release.promotionalText?.current.firstIndex(where: { $0.locale == text.locale }) else { continue }
                    release.promotionalText?.current[index].text = text.text
                }
                release.promotionalText?.request = .done(Date())
            }
        }
    }
}

extension DemoClientService {
    /// リリースの操作。司令塔が受け付けて、App Store Connect に出す・配信する・取り下げるのをまねる（審査の結果までは進めない）
    func applySubmissionIntent(_ intent: HumanIntent) {
        switch intent {
        case let .startRelease(repositoryID, version):
            startRelease(repositoryID: repositoryID, version: version)

        case let .startHotfix(repositoryID, version, suspend):
            startHotfix(repositoryID: repositoryID, version: version, suspend: suspend)

        case let .submitForReview(repositoryID, version, request):
            submitForReview(repositoryID, version: version, request: request)

        case let .distributeRelease(repositoryID, version):
            updateSoon(Submission.id(repositoryID, version), sending: .distribute) { submission in
                submission.awaitsDistribution = false
                submission.distribution = .done
            }

        case let .withdrawSubmission(repositoryID, version):
            updateSoon(Submission.id(repositoryID, version), sending: .withdraw) { submission in
                submission.canWithdraw = false
                submission.submitted = nil
                submission.review = submission.review.map { .init(platform: $0.platform, state: .withdrawn, since: Date()) }
                submission.awaitsSubmission = true
                submission.canAbandon = true
            }

        case let .abandonRelease(repositoryID, version):
            updateSoon(Submission.id(repositoryID, version), sending: .abandon) { submission in
                submission.end = .abandoned
                submission.awaitsSubmission = false
            }

        case let .reportRejection(repositoryID, version, text, images):
            reportRejection(Submission.id(repositoryID, version), text: text, imageCount: images.count)

        case let .resolveRejection(repositoryID, version, remedy):
            resolveRejection(Submission.id(repositoryID, version), remedy: remedy)

        case let .retakeScreenshots(repositoryID, version, _, _):
            updateSoon(Submission.id(repositoryID, version), sending: .retake) { submission in
                submission.screenshots?.state = .capturing
                submission.screenshots?.progress = "GitHub Actions の撮影を待っています"
                submission.awaitsSubmission = false
                submission.canRetakeScreenshots = false
            }

        default:
            break
        }
    }

    /// hotfix を始める。進行中のリリースは一時停止する
    private func startHotfix(repositoryID: TargetRepository.ID, version: String, suspend: String?) {
        if let suspend {
            state.updateSubmission(Submission.id(repositoryID, suspend)) { submission in
                submission.suspendedBy = version
                submission.awaitsSubmission = false
            }
        }
        startRelease(repositoryID: repositoryID, version: version)
        let from = state.releases(of: repositoryID).max { ClientSnapshot.isOlder($0.version, $1.version) }?.version
        state.updateSubmission(Submission.id(repositoryID, version)) { $0.hotfixFrom = from }
    }

    /// リジェクトの直し方を受け付ける（審査に出した中身を消す。コードを直すなら、直した後のビルドを待つ）
    private func resolveRejection(_ id: Submission.ID, remedy: Submission.Remedy) {
        updateSoon(id, sending: .resolveRejection) { submission in
            submission.rejection?.choice = remedy
            submission.awaitsRejectionChoice = false
            submission.canReportRejection = false
            submission.submitted = nil
            submission.awaitsFixedBuild = remedy == .code
            submission.awaitsSubmission = remedy != .code
        }
    }

    private func startRelease(repositoryID: TargetRepository.ID, version: String) {
        let now = Date()
        let id = Submission.id(repositoryID, version)
        state.submissions.append(Submission(
            repositoryID: repositoryID,
            version: version,
            startedInAskHub: true,
            revision: 0,
            createdAt: now,
            updatedAt: now,
            sending: .start
        ))
        schedule { $0.updateSubmission(id) { $0.sending = nil } }
        schedule(after: 2) { $0.updateSubmission(id) { $0.branch = "release/\(version)" } }
    }

    /// 審査に出す。承認したクリエイティブアセットを載せるなら、載せたことにする
    private func submitForReview(_ repositoryID: TargetRepository.ID, version: String, request: Submission.SubmitRequest) {
        let id = Submission.id(repositoryID, version)
        if let index = state.creatives.firstIndex(where: { $0.repositoryID == repositoryID }),
           let revision = request.creative, state.creatives[index].approved?.revision == revision {
            state.creatives[index].approved?.placedIn = version
        }
        state.updateSubmission(id) { submission in
            submission.awaitsSubmission = false
            submission.canAbandon = false
        }
        updateSoon(id, sending: .submit) { submission in
            submission.submitted = .init(
                builds: request.builds,
                whatsNew: request.whatsNew,
                releaseType: request.releaseType,
                at: Date(),
                listing: request.listing,
                appReview: request.appReview
            )
            submission.review = request.builds.map { .init(platform: $0.platform, state: .waitingForReview, since: Date()) }
            submission.canWithdraw = true
        }
    }

    /// 送った印を付け、司令塔が受け付けたら印を外して `change` を当てる
    /// リジェクトの理由を受け付け、少し後に Claude の直し方の案ができたことにする（デモの決まった案）
    private func reportRejection(_ id: Submission.ID, text: String, imageCount: Int) {
        let now = Date()
        updateSoon(id, sending: .reportRejection) { submission in
            submission.rejection = Submission.Rejection(
                platforms: submission.review.filter { $0.state == .rejected }.map(\.platform),
                text: text,
                images: (0..<imageCount).map { .init(path: "demo/rejection/\($0 + 1)", name: "審査の文 \($0 + 1).png") },
                reportedAt: now
            )
            submission.awaitsRejectionReport = false
        }
        schedule(after: 2) { snapshot in
            snapshot.updateSubmission(id) { submission in
                submission.rejection?.triage = DemoData.rejectionTriage
                submission.awaitsRejectionChoice = true
            }
        }
    }

    private func updateSoon(_ id: Submission.ID, sending: Submission.Action, _ change: @escaping (inout Submission) -> Void) {
        state.updateSubmission(id) { $0.sending = sending }
        schedule { snapshot in
            snapshot.updateSubmission(id) { submission in
                submission.sending = nil
                change(&submission)
            }
        }
    }
}

extension ClientSnapshot {
    mutating func updateSubmission(_ id: Submission.ID, _ change: (inout Submission) -> Void) {
        guard let index = submissions.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&submissions[index])
    }

    mutating func updateRelease(_ id: Release.ID, _ change: (inout Release) -> Void) {
        guard let index = releases.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&releases[index])
    }
}
