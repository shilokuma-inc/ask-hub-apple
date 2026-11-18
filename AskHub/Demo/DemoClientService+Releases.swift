import Foundation

// MARK: - 人の意図を当てる（配信した版）

extension DemoClientService {
    /// リリース文の公開。司令塔が受け付けて本文を記録に写し、次の見回りで GitHub Release を公開するのをまねる
    func applyReleaseIntent(_ intent: HumanIntent) {
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
    /// リリースの操作。司令塔が受け付けて、App Store Connect に出す・配信する・取り下げるのをまねる（審査の結果までは進めない）
    func applySubmissionIntent(_ intent: HumanIntent) {
        switch intent {
        case let .startRelease(repositoryID, version):
            startRelease(repositoryID: repositoryID, version: version)

        case let .submitForReview(repositoryID, version, request):
            submitForReview(Submission.id(repositoryID, version), request: request)

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

        default:
            break
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

    private func submitForReview(_ id: Submission.ID, request: Submission.SubmitRequest) {
        state.updateSubmission(id) { submission in
            submission.awaitsSubmission = false
            submission.canAbandon = false
        }
        updateSoon(id, sending: .submit) { submission in
            submission.submitted = .init(builds: request.builds, whatsNew: request.whatsNew, releaseType: request.releaseType, at: Date())
            submission.review = request.builds.map { .init(platform: $0.platform, state: .waitingForReview, since: Date()) }
            submission.canWithdraw = true
        }
    }

    /// 送った印を付け、司令塔が受け付けたら印を外して `change` を当てる
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
