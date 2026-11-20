@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// 審査に出す・配信する・取り下げの人の意図（`SubmitForReviewHandler` など）
extension SubmissionHandlersTests {
    func submitEnvelope(
        revision: String = "2",
        releaseType: String = "afterApproval",
        locales: [String] = ["ja"],
        listing: [ListingText] = []
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: SubmitForReviewIntent.kind,
            repo: ReleaseWatchTests.repo,
            target: .init(type: "submission", id: "1.2.0"),
            targetVersion: revision,
            payload: SubmitForReviewIntent.payload(
                builds: [.init(platform: .iOS, build: "45")],
                whatsNew: locales.map { LocalizedText(locale: $0, text: "・\($0) を直した") },
                releaseType: AppStoreReleaseType(rawValue: releaseType)!,
                earliestReleaseDate: nil,
                listing: listing
            ),
            issuedAt: Timestamp(ReleaseWatchTests.now),
            nonce: ULID(rawValue: "01JCN0NCE00000000000000005")!,
            keyId: Self.keyID
        )
    }

    static func prepared() -> SubmissionFile {
        var file = started()
        let now = Timestamp(ReleaseWatchTests.now)
        file.branch = .init(name: "release/1.2.0", commit: ReleaseWatchTests.developHead, created: true, at: now)
        file.whatsNew = .init(drafts: [.init(locale: "ja", text: "・下書き")], draftedAt: now)
        file.listing = .init(
            current: [.init(locale: "ja", description: "推しの予定を数えるアプリ", keywords: "推し活")],
            drafts: [.init(locale: "ja", keywords: "推し活,ウィジェット")],
            reason: "ウィジェットを足したので、キーワードに入れる案です",
            draftedAt: now
        )
        file.builds = [.init(platform: .iOS, build: "45", uploadedAt: now)]
        file.revision = 2
        return file
    }

    @Test func recordsSubmitOnlyForWhatHumanSaw() async throws {
        try await put(Self.prepared())
        let handler = SubmitForReviewHandler()
        // 準備の版が違う・言語が違う
        #expect(try await handler.handle(submitEnvelope(revision: "1"), in: context) != .accept)
        #expect(try await handler.handle(submitEnvelope(locales: ["ja", "en-US"]), in: context) != .accept)
        #expect(try await file()?.submit == nil)
        #expect(try await handler.handle(submitEnvelope(releaseType: "manual"), in: context) == .accept)
        let submit = try #require(try await file()?.submit)
        #expect(submit.releaseType == .manual && submit.builds == [.init(platform: .iOS, build: "45")])
        #expect(submit.whatsNew == [.init(locale: "ja", text: "・ja を直した")])
        #expect(submit.listing?.isEmpty == true)
        // やり直しは受け付ける
        #expect(try await handler.handle(submitEnvelope(releaseType: "manual"), in: context) == .accept)
    }

    @Test func recordsListingOnlyForLiveLocales() async throws {
        try await put(Self.prepared())
        let handler = SubmitForReviewHandler()
        // 配信中の版に無い言語は断る
        let unknown = [ListingText(locale: "fr", keywords: "oshi")]
        #expect(try await handler.handle(submitEnvelope(listing: unknown), in: context) != .accept)
        let changes = [ListingText(locale: "ja", description: "推しの予定を数え、ウィジェットにも出せるアプリ", promotionalText: "")]
        #expect(try await handler.handle(submitEnvelope(listing: changes), in: context) == .accept)
        #expect(try await file()?.submit?.listing == changes)
    }

    @Test func recordsDistributionAndWithdrawalByState() async throws {
        var record = Self.prepared()
        record.submit = .init(
            approval: record.start!.approval,
            at: record.createdAt,
            builds: [.init(platform: .iOS, build: "45")],
            whatsNew: [],
            releaseType: .manual
        )
        record.review = [.init(platform: .iOS, state: .inReview, since: record.createdAt, submittedAt: record.createdAt)]
        try await put(record)
        // 審査中は配信できず、取り下げられる
        #expect(try await DistributeReleaseHandler().handle(envelope("distributeRelease"), in: context) != .accept)
        #expect(try await WithdrawSubmissionHandler().handle(envelope("withdrawSubmission"), in: context) == .accept)
        #expect(try await file()?.withdrawal?.doneAt == nil)
        // 取り下げを送っている間は、もう一度は受け付けない
        let again = envelope("withdrawSubmission", nonce: "01JCN0NCE00000000000000006")
        #expect(try await WithdrawSubmissionHandler().handle(again, in: context) != .accept)

        record.withdrawal = nil
        record.review = [.init(platform: .iOS, state: .pendingDeveloperRelease, since: record.createdAt, submittedAt: record.createdAt)]
        try await put(record)
        let approved = envelope("withdrawSubmission", nonce: "01JCN0NCE00000000000000007")
        #expect(try await WithdrawSubmissionHandler().handle(approved, in: context) != .accept)
        #expect(try await DistributeReleaseHandler().handle(envelope("distributeRelease"), in: context) == .accept)
        #expect(try await file()?.distribution?.approval.nonce.rawValue == "01JCN0NCE00000000000000001")
    }
}

/// App Store Connect に出す・配信する・取り下げと、審査の状態の見張り
extension ReleaseWatchTests {
    func putSubmission(_ file: SubmissionFile) async throws {
        await store.put(StatePath.submission(Self.repo, file.version), data: try StateFileCoder.encode(file))
    }

    /// App Store Connect の 1.2.0 の iOS の版
    func version(_ state: AppStoreVersionState) -> AppStoreVersionInfo {
        AppStoreVersionInfo(id: "v-1-2-0", platform: .iOS, versionString: "1.2.0", state: state)
    }

    func readyToSubmit(releaseType: AppStoreReleaseType = .afterApproval, listing: [ListingText] = []) async throws -> SubmissionFile {
        try await startRelease()
        hosting.state.withLock { $0.branches["release/1.2.0"] = Self.developHead }
        var file = SubmissionHandlersTests.prepared()
        file.nextVersion = .init(version: MarketingVersion(rawValue: "1.3.0")!, state: .skipped, at: file.createdAt)
        let drafts: [LocalizedText] = [.init(locale: "ja", text: "・下書き"), .init(locale: "en-US", text: "- Draft")]
        file.whatsNew = .init(drafts: drafts, draftedAt: file.createdAt)
        file.submit = .init(
            approval: IntentReference(keyId: SubmissionHandlersTests.keyID, nonce: ULID(rawValue: "01JCN0NCE00000000000000005")!),
            at: Timestamp(Self.now),
            builds: [.init(platform: .iOS, build: "45")],
            whatsNew: [.init(locale: "ja", text: "・速くなりました"), .init(locale: "en-US", text: "- Faster")],
            releaseType: releaseType,
            listing: listing
        )
        try await putSubmission(file)
        appStore.state.withLock { state in
            // release ブランチを作ったとき（今）に上げたビルド
            state.builds = [build("45", minutesFromNow: 0)]
            state.localizations["v-1-2-0"] = [
                AppStoreLocalization(
                    id: "l-ja",
                    locale: "ja",
                    whatsNew: nil,
                    listing: .init(locale: "ja", description: "推しの予定を数えるアプリ", keywords: "推し活", promotionalText: "毎日に推しを")
                ),
                // 2 つ目以降の版は、App Store Connect が前の版の掲載文を写す
                AppStoreLocalization(
                    id: "l-en",
                    locale: "en-US",
                    whatsNew: "- Faster",
                    listing: .init(locale: "en-US", description: "Count down to your oshi events", keywords: "oshi")
                )
            ]
        }
        return file
    }

    @Test func writesOnlyChangedListingFields() async throws {
        let listing = [
            // キーワードは今の文と同じなので書かない。プロモーションテキストは空にする
            ListingText(locale: "ja", description: "推しの予定を数え、ウィジェットにも出せるアプリ", keywords: "推し活", promotionalText: ""),
            // 英語は今の文と同じなので書かない
            ListingText(locale: "en-US", promotionalText: "")
        ]
        _ = try await readyToSubmit(listing: listing)
        await watch().refresh()
        let writes = appStore.state.withLock { $0.writes }
        #expect(writes == [
            "createVersion iOS 1.2.0 afterApproval b45",
            "updateWhatsNew l-ja ・速くなりました",
            "updateListing l-ja description=推しの予定を数え、ウィジェットにも出せるアプリ promotionalText=",
            "createReviewSubmission iOS",
            "addToReviewSubmission s-iOS v-1-2-0",
            "submitReviewSubmission s-iOS"
        ])
    }

    @Test func submitsToAppStoreConnectOnce() async throws {
        _ = try await readyToSubmit()
        let watch = watch()
        await watch.refresh()
        let writes = appStore.state.withLock { $0.writes }
        #expect(writes == [
            "createVersion iOS 1.2.0 afterApproval b45",
            "updateWhatsNew l-ja ・速くなりました",
            "createReviewSubmission iOS",
            "addToReviewSubmission s-iOS v-1-2-0",
            "submitReviewSubmission s-iOS"
        ])
        let file = try await submission()
        #expect(file.review.map(\.state) == [.waitingForReview])
        #expect(file.review.first?.submittedAt == Timestamp(Self.now))
        #expect(!file.isSubmitting && file.problem == nil)
        // 出し終えたら、もう一度は出さない
        await watch.refresh()
        #expect(appStore.state.withLock { $0.writes }.count == writes.count)
    }

    @Test func reusesEditableVersionAndReportsRefusal() async throws {
        _ = try await readyToSubmit()
        appStore.state.withLock { state in
            // やめたリリースで作った版（番号を直して使う）
            state.others = [AppStoreVersionInfo(id: "v-old", platform: .iOS, versionString: "1.1.9", state: .prepareForSubmission)]
            state.localizations["v-old"] = [
                AppStoreLocalization(
                    id: "l-ja", locale: "ja", whatsNew: nil, listing: .init(locale: "ja", description: "推し活", keywords: "推し")
                ),
                AppStoreLocalization(
                    id: "l-en", locale: "en-US", whatsNew: nil, listing: .init(locale: "en-US", description: "Oshi", keywords: "oshi")
                )
            ]
            state.refusal = .refused(status: 409, detail: "You must upload screenshots.")
        }
        let watch = watch()
        await watch.refresh()
        let file = try await submission()
        #expect(file.isSubmitting)
        #expect(file.problem?.step == .submit && file.problem?.needsHuman == true)
        #expect(file.problem?.message.contains("You must upload screenshots.") == true)
        #expect(await submissionBlockers(watch).map(\.reason) == [.submissionProblem(.submit)])

        appStore.state.withLock { $0.refusal = nil }
        clock.advance(minutes: 31)
        await watch.refresh()
        #expect(appStore.state.withLock { $0.writes }.first == "updateVersion v-old 1.2.0 afterApproval b45")
        #expect(try await submission().problem == nil)
    }

    @Test func tracksReviewStatesAndNotifies() async throws {
        var file = try await readyToSubmit(releaseType: .manual)
        file.review = [.init(platform: .iOS, state: .waitingForReview, since: Timestamp(Self.now), submittedAt: Timestamp(Self.now))]
        try await putSubmission(file)
        let inReview = AppStoreVersionInfo(id: "v-1-2-0", platform: .iOS, versionString: "1.2.0", state: .inReview)
        appStore.state.withLock { $0.others = [inReview] }
        let watch = watch()
        await watch.refresh()
        #expect(try await submission().review.map(\.state) == [.inReview])
        #expect(await submissionBlockers(watch).map(\.reason) == [.reviewState(.iOS, .inReview)])

        // 承認された（手動の配信）。人が配信するを押すと、見回りが配信する
        appStore.state.withLock { $0.others = [self.version(.pendingDeveloperRelease)] }
        clock.advance(minutes: 31)
        await watch.refresh()
        var approved = try await submission()
        #expect(approved.awaitsDistribution)
        #expect(await submissionBlockers(watch).map(\.reason) == [.reviewState(.iOS, .pendingDeveloperRelease)])
        approved.distribution = .init(approval: approved.start!.approval, at: Timestamp(clock.now))
        try await putSubmission(approved)
        await watch.refresh()
        #expect(appStore.state.withLock { $0.writes }.last == "requestRelease v-1-2-0")
        #expect(try await submission().distribution?.doneAt != nil)

        // 配信を見つけたら終え、配信の知らせを出す。GitHub Release は審査に出したときの What's New で公開する
        appStore.state.withLock { state in
            state.others = []
            let uploaded = Self.now.addingTimeInterval(-300)
            state.versions = [LiveAppVersion(platform: .iOS, version: Self.next, build: "45", uploadedAt: uploaded)]
            state.apps = [AppStoreApp(id: "6740000001", bundleId: "jp.shilokuma.OshiCon", name: "推し活カウントダウン")]
        }
        hosting.state.withLock { $0.tags["v1.2.0"] = Self.released }
        await watch.refresh()
        let ended = try await submission()
        #expect(ended.end?.reason == .distributed)
        #expect(await submissionBlockers(watch).map(\.reason) == [.submissionDistributed])
        let release = try StateFileCoder.decode(
            ReleaseFile.self, from: try #require(await store.data(at: StatePath.release(Self.repo, Self.next)))
        )
        #expect(release.notes?.confirmed?.text == "・速くなりました")
        #expect(release.githubRelease != nil)
        #expect(hosting.state.withLock { $0.releases["v1.2.0"] } == "・速くなりました")
        #expect(drafter.materials.withLock { $0 }.isEmpty)
    }

    @Test func withdrawsAndAllowsResubmit() async throws {
        var file = try await readyToSubmit()
        file.review = [.init(platform: .iOS, state: .waitingForReview, since: Timestamp(Self.now), submittedAt: Timestamp(Self.now))]
        file.withdrawal = .init(approval: file.start!.approval, at: Timestamp(Self.now))
        try await putSubmission(file)
        appStore.state.withLock { state in
            state.others = [AppStoreVersionInfo(id: "v-1-2-0", platform: .iOS, versionString: "1.2.0", state: .waitingForReview)]
            state.submissions = [AppStoreReviewSubmission(id: "s1", platform: .iOS, state: .waitingForReview, versionID: "v-1-2-0")]
        }
        let watch = watch()
        await watch.refresh()
        #expect(appStore.state.withLock { $0.writes } == ["cancelReviewSubmission s1"])
        var withdrawn = try await submission()
        #expect(withdrawn.submit == nil && withdrawn.withdrawal?.doneAt != nil)
        // 取り下げが済んだら（Developer Rejected）、出し直せる
        appStore.state.withLock { $0.others = [self.version(.developerRejected)] }
        await watch.refresh()
        withdrawn = try await submission()
        #expect(withdrawn.review.map(\.state) == [.developerRejected])
        #expect(withdrawn.awaitsSubmission && withdrawn.canAbandon)
    }

    @Test func recordsVersionsSubmittedByHand() async throws {
        try await addRepository()
        live()
        appStore.state.withLock { state in
            state.others = [
                AppStoreVersionInfo(id: "v-1.3.0", platform: .iOS, versionString: "1.3.0", state: .rejected),
                // 配信中の版より古い・まだ出していない版は記録しない
                AppStoreVersionInfo(id: "v-1.0.9", platform: .iOS, versionString: "1.0.9", state: .rejected),
                AppStoreVersionInfo(id: "v-1.4.0", platform: .macOS, versionString: "1.4.0", state: .prepareForSubmission)
            ]
        }
        let watch = watch()
        await watch.refresh()
        let data = try #require(await store.data(at: StatePath.submission(Self.repo, MarketingVersion(rawValue: "1.3.0")!)))
        let found = try StateFileCoder.decode(SubmissionFile.self, from: data)
        #expect(found.origin == .appStoreConnect && found.review.map(\.state) == [.rejected])
        #expect(await store.data(at: StatePath.submission(Self.repo, MarketingVersion(rawValue: "1.0.9")!)) == nil)
        #expect(await store.data(at: StatePath.submission(Self.repo, MarketingVersion(rawValue: "1.4.0")!)) == nil)
        // 次の見回りで、リジェクトを知らせる
        clock.advance(minutes: 31)
        await watch.refresh()
        let scope = Blocker.Scope.submission(Self.repo, MarketingVersion(rawValue: "1.3.0")!)
        #expect(await watch.blockers.filter { $0.scope == scope }.map(\.reason) == [.reviewState(.iOS, .rejected)])
    }
}

/// 配信した後に、release ブランチを main と develop に取り込む
extension ReleaseWatchTests {
    func distributedSubmission() async throws -> SubmissionFile {
        try await addRepository()
        var file = SubmissionHandlersTests.prepared()
        file.end = .init(reason: .distributed, at: file.createdAt)
        try await putSubmission(file)
        hosting.state.withLock { state in
            state.branches = ["develop": Self.developHead, "release/1.2.0": Self.released, "main": Self.epicMerge]
        }
        return file
    }

    @Test func integratesReleaseBranchIntoMainOnly() async throws {
        _ = try await distributedSubmission()
        // release ブランチに直しが入っていなければ develop には取り込まない。main には PR を出す
        hosting.state.withLock { $0.ahead["main...release/1.2.0"] = 3 }
        let watch = watch()
        await watch.refresh()
        var file = try await submission()
        #expect(file.integration?.first { $0.base == "develop" }?.state == .skipped)
        #expect(file.integration?.first { $0.base == "main" }?.state == .open)
        let opened = try #require(hosting.state.withLock { $0.opened.last })
        #expect(opened.base == "main" && opened.head == "release/1.2.0")
        #expect(opened.title == "【CHORE】release/1.2.0 を main に取り込む")

        // チェックが通ったらマージし、取り込みを終える
        hosting.state.withLock { $0.checks = CheckSummary(verdict: .passed) }
        await watch.refresh()
        file = try await submission()
        #expect(file.integration?.first { $0.base == "main" }?.state == .merged)
        #expect(!file.awaitsIntegration(bases: ["develop", "main"]))
        #expect(hosting.state.withLock { $0.merged } == [170])
    }

    @Test func createsMainWhenMissing() async throws {
        _ = try await distributedSubmission()
        hosting.state.withLock { $0.branches["main"] = nil }
        await watch().refresh()
        let file = try await submission()
        #expect(file.integration?.first { $0.base == "main" }?.state == .created)
        #expect(hosting.state.withLock { $0.branches["main"] } == Self.released)
    }

    @Test func asksHumanWhenIntegrationIsClosed() async throws {
        var file = try await distributedSubmission()
        file.integration = [
            .init(base: "develop", state: .skipped, at: file.createdAt),
            .init(base: "main", state: .open, pullRequest: 170, at: file.createdAt)
        ]
        try await putSubmission(file)
        hosting.state.withLock { state in
            state.pull = PullRequest(number: 170, state: .closed, merged: false, head: ("release/1.2.0", Self.released), baseRef: "main")
        }
        let watch = watch()
        await watch.refresh()
        #expect(try await submission().problem?.step == .integration)
        // 配信してから 1 日の間は、配信の知らせも出し続ける
        #expect(await submissionBlockers(watch).map(\.reason) == [.submissionProblem(.integration), .submissionDistributed])
    }
}

/// 審査に出す前に、提出先の版のどの言語にも説明文とキーワードがそろうかを確かめる（初めての版で、後から足した版・「変える」を外した欄）
extension ReleaseWatchTests {
    @Test func stopsBeforeSubmittingWhenRequiredListingIsEmpty() {
        let localizations = [
            AppStoreLocalization(id: "l-ja", locale: "ja", whatsNew: nil, listing: .init(locale: "ja", description: "日数を数えます。")),
            AppStoreLocalization(id: "l-en", locale: "en-US", whatsNew: nil, listing: .init(locale: "en-US"))
        ]
        // 人が「変える」を外した（直しが無い）
        #expect(AppStoreSubmission.missingRequired(localizations, changes: []) == [
            "ja の keywords", "en-US の description", "en-US の keywords"
        ])
        // 人が確かめた直しを当てるとそろう
        let changes = [
            ListingText(locale: "ja", keywords: "推し活"),
            ListingText(locale: "en-US", description: "Counts days.", keywords: "oshi")
        ]
        #expect(AppStoreSubmission.missingRequired(localizations, changes: changes).isEmpty)
    }

    @Test func doesNotSubmitVersionWithEmptyListing() async throws {
        _ = try await readyToSubmit()
        // 後から足した版のように、英語の掲載文が空
        appStore.state.withLock { state in
            state.localizations["v-1-2-0"]?[1] = AppStoreLocalization(id: "l-en", locale: "en-US", whatsNew: "- Faster")
        }
        let watch = watch()
        await watch.refresh()
        let file = try await submission()
        #expect(file.problem?.step == .submit && file.problem?.needsHuman == true)
        #expect(file.problem?.message.contains("en-US の description・en-US の keywords") == true)
        // 掲載文も提出も書かない（版を作るだけ）
        #expect(appStore.state.withLock { $0.writes } == ["createVersion iOS 1.2.0 afterApproval b45"])
    }

    @Test func doesNotSubmitVersionWithoutLocales() async throws {
        _ = try await readyToSubmit()
        appStore.state.withLock { $0.localizations["v-1-2-0"] = [] }
        await watch().refresh()
        let file = try await submission()
        #expect(file.problem?.step == .submit && file.problem?.needsHuman == true)
        #expect(file.problem?.message.contains("掲載文の言語が無い") == true)
        #expect(appStore.state.withLock { $0.writes } == ["createVersion iOS 1.2.0 afterApproval b45"])
    }
}
