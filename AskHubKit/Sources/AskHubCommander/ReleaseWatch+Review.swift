import AskHubProtocol
import AskHubStateStore
import Foundation

/// 審査に出す・配信する・取り下げと、審査の状態の見張り（`docs/renewal/release.md` の「リリースを始めてから配信まで」の 6〜10）。
/// App Store Connect への書き込みは、人の意図（`submitForReview`・`distributeRelease`・`withdrawSubmission`）を受け付けた記録があるときだけ行う。
/// どれも、する前に今の様子を読み、途中で止まってもやり直せば同じになる
extension ReleaseWatch {
    /// 状態を知らせる、審査に出してから配信までの状態（審査中・承認・リジェクト）
    static let noticeStates: Set<AppStoreVersionState> = [
        .inReview, .pendingDeveloperRelease, .pendingAppleRelease, .processingForDistribution, .accepted, .rejected, .metadataRejected,
        .invalidBinary
    ]
    /// 記録が無ければ、手で審査に出した版として記録を作る状態
    static let foundStates: Set<AppStoreVersionState> = noticeStates.union([.waitingForReview, .waitingForExportCompliance])
    /// 配信を見つけてから、配信の知らせを出し続ける長さ（通知が送れなかったときに送り直せるように）
    static let distributedNoticeWindow: TimeInterval = 24 * 60 * 60

    // MARK: - 人が押した操作

    /// 人が押した操作（審査に出す・配信する・取り下げ）のうち、まだ App Store Connect に送っていないものを送る
    func performRequests(_ submission: SubmissionFile, settings: RepositoryFile) async -> SubmissionFile {
        var file = submission
        if file.origin == .askhub, file.isSubmitting {
            file = await submissionStep(.submit, file) { try await self.submit($0, settings: settings) }
        }
        if let distribution = file.distribution, distribution.doneAt == nil {
            file = await submissionStep(.distribute, file) { try await self.distribute($0, settings: settings) }
        }
        if let withdrawal = file.withdrawal, withdrawal.doneAt == nil {
            file = await submissionStep(.withdraw, file) { try await self.withdraw($0, settings: settings) }
        }
        return file
    }

    /// 審査に出す（プラットフォームごとに、版を作るか直し、ビルドを選び、What's New を書き、提出する）
    func submit(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard let request = file.submit else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        let builds = try await appStoreConnect { () throws(AppStoreConnectError) in
            try await store.builds(of: app.id, version: file.version)
        }
        var file = file
        let submission = AppStoreSubmission(store: store, app: app, version: file.version, request: request)
        for choice in request.builds {
            let review = file.review.first { $0.platform == choice.platform }
            if let submitted = review?.submittedAt, submitted >= request.at { continue }
            guard let build = builds.first(where: { $0.platform == choice.platform && $0.number == choice.build }) else {
                throw ReleaseStepProblem(
                    "ビルド \(choice.platform.rawValue) (\(choice.build)) が App Store Connect に無い（期限が切れた・まだ処理中）。"
                        + "新しいビルドで出し直す",
                    needsHuman: true
                )
            }
            let state = try await submission.send(build, versions: versions)
            log("\(file.repo) の \(file.version)（\(choice.platform.rawValue) のビルド \(choice.build)）を審査に出した")
            file.review.removeAll { $0.platform == choice.platform }
            file.review.append(.init(platform: choice.platform, state: state, since: context.timestamp, submittedAt: context.timestamp))
        }
        // 提出の直後に、次の見回りで状態を読み直す
        detectedAt[file.repo] = nil
        return file
    }

    /// 承認された（Pending Developer Release の）版を配信する。App Store Connect では取り消せない
    func distribute(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard file.distribution != nil else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        let pending = versions.filter { $0.versionString == file.version.rawValue && $0.state == .pendingDeveloperRelease }
        for version in pending {
            try await appStoreConnect { () throws(AppStoreConnectError) in try await store.requestRelease(of: version.id) }
            log("\(file.repo) の \(file.version)（\(version.platform.rawValue)）を配信した")
        }
        if pending.isEmpty { log("\(file.repo) の \(file.version) は配信を待つ状態でなくなっていた（App Store Connect で配信した）") }
        var file = file
        file.distribution?.doneAt = context.timestamp
        detectedAt[file.repo] = nil
        return file
    }

    /// 審査を待っている・審査中の提出を取り下げる。取り下げたら、審査に出した中身を消す（出し直せる）
    func withdraw(_ file: SubmissionFile, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard file.withdrawal != nil else { return nil }
        let (store, app) = try await submissionApp(file.repo, settings: settings)
        let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        for version in versions where version.versionString == file.version.rawValue && version.state.isUnderReview {
            let submissions = try await appStoreConnect { () throws(AppStoreConnectError) in
                try await store.reviewSubmissions(of: app.id, platform: version.platform)
            }
            for submission in submissions where submission.versionID == version.id
                && (submission.state == .waitingForReview || submission.state == .inReview) {
                try await appStoreConnect { () throws(AppStoreConnectError) in try await store.cancelReviewSubmission(submission.id) }
                log("\(file.repo) の \(file.version)（\(version.platform.rawValue)）の審査を取り下げた")
            }
        }
        var file = file
        file.withdrawal?.doneAt = context.timestamp
        file.submit = nil
        detectedAt[file.repo] = nil
        return file
    }

    // MARK: - 審査の状態の見張り

    /// App Store Connect で読んだ版の状態を、リリースを始めた版の記録に書く。記録の無い版を審査に出していれば、手で出した版として記録を作る。
    /// 配信中の版（とそれより古い版）の記録は終える
    func trackReview(_ repo: RepositoryFullName, versions: [AppStoreVersionInfo]) async {
        let liveMax = versions.filter { $0.state == .readyForDistribution }.compactMap(\.version).max()
        var byVersion: [MarketingVersion: [AppStoreVersionInfo]] = [:]
        for info in versions {
            guard let version = info.version else { continue }
            byVersion[version, default: []].append(info)
        }
        let files: [SubmissionFile]
        do {
            files = try await StartReleaseHandler.submissions(of: repo, in: context)
        } catch {
            report("\(repo) のリリースの記録を読めない（\(error)）。次に読むときにやり直す")
            return
        }
        for file in files where !file.isEnded {
            await updateReview(file, seen: byVersion[file.version] ?? [], liveMax: liveMax)
        }
        // 記録の無い版を審査に出していれば、手で出した版として記録を作る（配信中の版より新しいものだけ）
        for (version, infos) in byVersion where !files.contains(where: { $0.version == version }) {
            guard liveMax.map({ version > $0 }) ?? true, infos.contains(where: { Self.foundStates.contains($0.state) }) else { continue }
            await recordFound(repo, version: version, infos: infos)
        }
    }

    private func updateReview(_ file: SubmissionFile, seen: [AppStoreVersionInfo], liveMax: MarketingVersion?) async {
        do {
            try await writeReview(file, seen: seen, liveMax: liveMax)
        } catch {
            report("\(file.repo) の \(file.version) の審査の状態を書けない（\(error)）。次に読むときにやり直す")
        }
    }

    nonisolated private func writeReview(
        _ file: SubmissionFile,
        seen: [AppStoreVersionInfo],
        liveMax: MarketingVersion?
    ) async throws(CommanderError) {
        let path = StatePath.submission(file.repo, file.version)
        let message = "\(file.repo) の \(file.version) の審査の状態"
        let now = context.timestamp
        try await context.writingResult { () throws(CommanderError) in
            do throws(StateFileStore.Failure) {
                try await context.files.update(SubmissionFile.self, at: path, message: message) { file in
                    guard !file.isEnded else { return false }
                    let before = file
                    Self.apply(seen, liveMax: liveMax, to: &file, at: now)
                    guard file != before else { return false }
                    file.updatedAt = now
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
    }

    /// 読んだ版の状態を記録に写す。配信中なら終わりの印を付け、もっと新しい版が配信中なら置き換わった印を付ける
    static func apply(_ seen: [AppStoreVersionInfo], liveMax: MarketingVersion?, to file: inout SubmissionFile, at now: Timestamp) {
        for info in seen {
            if let index = file.review.firstIndex(where: { $0.platform == info.platform }) {
                guard file.review[index].state != info.state else { continue }
                file.review[index].state = info.state
                file.review[index].since = now
            } else {
                file.review.append(.init(platform: info.platform, state: info.state, since: now))
            }
        }
        if seen.contains(where: { $0.state == .readyForDistribution }) {
            file.end = .init(reason: .distributed, at: now)
        } else if let liveMax, file.version < liveMax {
            file.end = .init(reason: .superseded, at: now)
        }
        if file.problem?.step == .review { file.problem = nil }
    }

    private func recordFound(_ repo: RepositoryFullName, version: MarketingVersion, infos: [AppStoreVersionInfo]) async {
        let now = context.timestamp
        var review: [SubmissionFile.Review] = []
        for info in infos where !review.contains(where: { $0.platform == info.platform }) {
            review.append(.init(platform: info.platform, state: info.state, since: now))
        }
        let file = SubmissionFile(repo: repo, version: version, origin: .appStoreConnect, review: review, createdAt: now, updatedAt: now)
        do {
            guard try await createFound(file) else { return }
            let states = review.map { "\($0.platform.rawValue): \($0.state.rawValue)" }.joined(separator: "・")
            log("\(repo) の \(version) が審査に出ているのを見つけた（\(states)）")
        } catch {
            report("\(repo) の \(version) の審査の記録を作れない（\(error)）。次に読むときにやり直す")
        }
    }

    /// 作ったら true。読んだ後に作られていたら false（次に読むときに状態を書く）
    nonisolated private func createFound(_ file: SubmissionFile) async throws(CommanderError) -> Bool {
        let path = StatePath.submission(file.repo, file.version)
        let message = "\(file.repo) の \(file.version) の審査を見つけた"
        return try await context.writingResult { () throws(CommanderError) -> Bool in
            do throws(StateFileStore.Failure) {
                try await context.files.create(file, at: path, message: message)
                return true
            } catch .alreadyExists {
                return false
            } catch {
                throw .files(error)
            }
        }
    }

    // MARK: - GitHub Release

    /// 審査に出したときに人が確かめた What's New（日本語。無ければ最初の言語）。リリースを始めていない・初めての版なら nil
    func confirmedWhatsNew(_ repo: RepositoryFullName, version: MarketingVersion) async -> (text: String, approval: IntentReference)? {
        guard let file = try? await context.readable(SubmissionFile.self, at: StatePath.submission(repo, version)),
              let submit = file.submit else { return nil }
        let texts = submit.whatsNew
        let japanese = texts.first { $0.locale == "ja" } ?? texts.first { $0.locale.hasPrefix("ja") }
        guard let text = japanese ?? texts.first else { return nil }
        return (text.text, submit.approval)
    }
}

extension Blocker {
    /// リリースを始めた版の審査の状態の知らせ（審査中・承認・リジェクト）と、配信の知らせ
    static func reviewNotices(on submission: SubmissionFile, now: Date) -> [Blocker] {
        let scope = Scope.submission(submission.repo, submission.version)
        let base = "submission/\(submission.repo.rawValue)/\(submission.version.rawValue)"
        if let end = submission.end {
            guard end.reason == .distributed, now.timeIntervalSince(end.at.date) < ReleaseWatch.distributedNoticeWindow else { return [] }
            return [Blocker(key: "\(base)/distributed", scope: scope, reason: .submissionDistributed)]
        }
        return submission.review.filter { ReleaseWatch.noticeStates.contains($0.state) }.map { review in
            Blocker(
                key: "\(base)/review/\(review.platform.rawValue)/\(review.state.rawValue)/\(review.since.rawValue)",
                scope: scope,
                reason: .reviewState(review.platform, review.state)
            )
        }
    }
}
