@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// リリースを始める・やめるの人の意図（`StartReleaseHandler`・`AbandonReleaseHandler`）
struct SubmissionHandlersTests {
    static let keyID = KeyID(rawValue: String(repeating: "k", count: 43))!
    static let next = MarketingVersion(rawValue: "1.2.0")!
    let store = InMemoryStateStore()

    var context: CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { ReleaseWatchTests.now }
    }

    func envelope(_ kind: String, version: String = "1.2.0", nonce: String = "01JCN0NCE00000000000000001") -> IntentEnvelope {
        let start = kind == StartReleaseIntent.kind
        return IntentEnvelope(
            kind: kind,
            repo: ReleaseWatchTests.repo,
            target: start ? nil : .init(type: "submission", id: version),
            targetVersion: nil,
            payload: start ? ["version": .string(version)] : [:],
            issuedAt: Timestamp(ReleaseWatchTests.now),
            nonce: ULID(rawValue: nonce)!,
            keyId: Self.keyID
        )
    }

    func addRepository(removed: Bool = false) async throws {
        var file = RepositoryFile(repo: ReleaseWatchTests.repo, platform: .apple, addedAt: Timestamp(ReleaseWatchTests.now))
        if removed { file.removedAt = Timestamp(ReleaseWatchTests.now) }
        await store.put(StatePath.repository(ReleaseWatchTests.repo), data: try StateFileCoder.encode(file))
    }

    func released(_ version: String) async throws {
        let now = Timestamp(ReleaseWatchTests.now)
        let release = MarketingVersion(rawValue: version)!
        let file = ReleaseFile(
            repo: ReleaseWatchTests.repo,
            version: release,
            platforms: [.init(platform: .iOS, build: "31", detectedAt: now)],
            detectedAt: now,
            updatedAt: now
        )
        await store.put(StatePath.release(ReleaseWatchTests.repo, release), data: try StateFileCoder.encode(file))
    }

    func put(_ file: SubmissionFile) async throws {
        await store.put(StatePath.submission(file.repo, file.version), data: try StateFileCoder.encode(file))
    }

    func file(_ version: MarketingVersion = Self.next) async throws -> SubmissionFile? {
        guard let data = await store.data(at: StatePath.submission(ReleaseWatchTests.repo, version)) else { return nil }
        return try StateFileCoder.decode(SubmissionFile.self, from: data)
    }

    static func started(_ version: MarketingVersion = next, nonce: String = "01JCN0NCE00000000000000009") -> SubmissionFile {
        let now = Timestamp(ReleaseWatchTests.now)
        let reference = IntentReference(keyId: keyID, nonce: ULID(rawValue: nonce)!)
        return SubmissionFile(
            repo: ReleaseWatchTests.repo,
            version: version,
            origin: .askhub,
            start: .init(approval: reference, at: now),
            createdAt: now,
            updatedAt: now
        )
    }

    @Test func startsReleaseAndAcceptsRetry() async throws {
        try await addRepository()
        try await released("1.1.0")
        let handler = StartReleaseHandler()
        #expect(try await handler.handle(envelope("startRelease"), in: context) == .accept)
        let file = try #require(try await file())
        #expect(file.origin == .askhub)
        #expect(file.start?.approval.nonce.rawValue == "01JCN0NCE00000000000000001")
        #expect(file.revision == 0 && file.branch == nil)
        // 同じ意図のやり直しは受け付け、別の意図は断る（もう始めている）
        #expect(try await handler.handle(envelope("startRelease"), in: context) == .accept)
        #expect(try await handler.handle(envelope("startRelease", nonce: "01JCN0NCE00000000000000002"), in: context) != .accept)
    }

    @Test func rejectsStartThatCannotBeReleased() async throws {
        let handler = StartReleaseHandler()
        // 対象に加えていない・外した
        #expect(try await handler.handle(envelope("startRelease"), in: context) != .accept)
        try await addRepository(removed: true)
        #expect(try await handler.handle(envelope("startRelease"), in: context) != .accept)
        try await addRepository()
        // 配信した版より大きくない
        try await released("1.2.0")
        #expect(try await handler.handle(envelope("startRelease"), in: context) != .accept)
        // 終わっていないほかの版がある
        try await put(Self.started(MarketingVersion(rawValue: "1.3.0")!))
        #expect(try await handler.handle(envelope("startRelease", version: "1.4.0"), in: context) != .accept)
        #expect(try await file(MarketingVersion(rawValue: "1.4.0")!) == nil)
    }

    @Test func restartsAbandonedVersion() async throws {
        try await addRepository()
        var abandoned = Self.started()
        abandoned.branch = .init(name: "release/1.2.0", commit: ReleaseWatchTests.developHead, created: true, at: abandoned.createdAt)
        abandoned.end = .init(reason: .abandoned, at: abandoned.createdAt, approval: abandoned.start?.approval)
        try await put(abandoned)
        #expect(try await StartReleaseHandler().handle(envelope("startRelease"), in: context) == .accept)
        let file = try #require(try await file())
        #expect(file.end == nil && file.branch == nil)
        #expect(file.start?.approval.nonce.rawValue == "01JCN0NCE00000000000000001")
    }

    @Test func abandonsOnlyBeforeReview() async throws {
        try await addRepository()
        var reviewing = Self.started()
        reviewing.review = [.init(platform: .iOS, state: .inReview, since: reviewing.createdAt)]
        try await put(reviewing)
        let handler = AbandonReleaseHandler()
        #expect(try await handler.handle(envelope("abandonRelease"), in: context) != .accept)
        #expect(try await file()?.end == nil)

        reviewing.review = [.init(platform: .iOS, state: .developerRejected, since: reviewing.createdAt)]
        try await put(reviewing)
        #expect(try await handler.handle(envelope("abandonRelease"), in: context) == .accept)
        let end = try #require(try await file()?.end)
        #expect(end.reason == .abandoned && end.approval?.nonce.rawValue == "01JCN0NCE00000000000000001")
        // やり直しは受け付け、ほかの意図は断る（もう終わっている）
        #expect(try await handler.handle(envelope("abandonRelease"), in: context) == .accept)
        #expect(try await handler.handle(envelope("abandonRelease", nonce: "01JCN0NCE00000000000000003"), in: context) != .accept)
    }
}

/// リリースを始めた版の準備（release ブランチ・次の版・What's New・ビルド）
extension ReleaseWatchTests {
    static let next = MarketingVersion(rawValue: "1.2.0")!

    func startRelease() async throws {
        try await addRepository()
        await store.put(StatePath.submission(Self.repo, Self.next), data: try StateFileCoder.encode(SubmissionHandlersTests.started()))
        hosting.state.withLock { $0.branches["develop"] = Self.developHead }
        sources.state.withLock { state in
            state.snapshot.files = [.init(path: "Configs/Project.xcconfig", content: "MARKETING_VERSION = 1.2.0\n")]
        }
        live()
        appStore.state.withLock { state in
            state.reviewDetails["live-0"] = AppStoreReviewDetail(
                id: "r-live", information: ReviewInformation(notes: "ログインは不要です。", demoAccountRequired: false)
            )
            state.localizations["live-0"] = [
                AppStoreLocalization(
                    id: "l-ja",
                    locale: "ja",
                    whatsNew: nil,
                    listing: .init(locale: "ja", description: "推しの予定を数えるアプリ", keywords: "推し活,カウントダウン")
                ),
                AppStoreLocalization(
                    id: "l-en",
                    locale: "en-US",
                    whatsNew: nil,
                    listing: .init(locale: "en-US", description: "Count down to your oshi events", promotionalText: "New!")
                )
            ]
        }
    }

    /// 始めた版の出来事（配信中の 1.1.0 の後作業の出来事は除く）
    func submissionBlockers(_ watch: ReleaseWatch) async -> [Blocker] {
        await watch.blockers.filter { $0.scope == .submission(Self.repo, Self.next) }
    }

    func submission() async throws -> SubmissionFile {
        let data = try #require(await store.data(at: StatePath.submission(Self.repo, Self.next)))
        return try StateFileCoder.decode(SubmissionFile.self, from: data)
    }

    func build(_ number: String, platform: AppStorePlatform = .iOS, minutesFromNow: Double, answered: Bool = true) -> AppStoreBuild {
        AppStoreBuild(
            id: "b\(number)",
            platform: platform,
            number: number,
            uploadedAt: Self.now.addingTimeInterval(minutesFromNow * 60),
            usesNonExemptEncryption: answered ? false : nil,
            expired: false
        )
    }

    @Test func preparesBranchNextVersionAndWhatsNew() async throws {
        try await startRelease()
        let watch = watch()
        await watch.refresh()
        let file = try await submission()
        // develop の先頭から release ブランチを作る
        #expect(file.branch == .init(name: "release/1.2.0", commit: Self.developHead, created: true, at: Timestamp(Self.now)))
        #expect(hosting.state.withLock { $0.branches["release/1.2.0"] } == Self.developHead)
        // release ブランチを作った後に、develop の版を次に上げる PR を出す
        #expect(file.nextVersion?.version.rawValue == "1.3.0")
        #expect(file.nextVersion?.state == .open)
        let committed = try #require(hosting.state.withLock { $0.committed.first })
        #expect(committed.files["Configs/Project.xcconfig"] == "MARKETING_VERSION = 1.3.0\n")
        // 配信中の版の掲載文の言語ごとに下書きする
        #expect(file.whatsNew?.drafts.map(\.locale) == ["ja", "en-US"])
        let material = try #require(whatsNewDrafter.materials.withLock { $0.first })
        #expect(material.commit == Self.developHead && material.locales == ["ja", "en-US"])
        // 配信中の版の掲載文をもとに、直す案を書く（今の文も残す）
        #expect(file.listing?.current.map(\.locale) == ["ja", "en-US"])
        #expect(file.listing?.current.last?.promotionalText == "New!")
        #expect(file.listing?.drafts == [.init(locale: "ja", keywords: "推し活,カウントダウン,ウィジェット")])
        let listingMaterial = try #require(listingDrafter.materials.withLock { $0.first })
        #expect(listingMaterial.commit == Self.developHead && listingMaterial.current.first?.keywords == "推し活,カウントダウン")
        // App Review の情報も同じ下書きで案を書く（今の情報はパスワードを持たない）
        #expect(listingMaterial.review == ReviewInformation(notes: "ログインは不要です。", demoAccountRequired: false))
        #expect(file.appReview?.current == ReviewInformation(notes: "ログインは不要です。", demoAccountRequired: false))
        #expect(file.appReview?.draft == ReviewInformation(notes: "ログインは不要です。ウィジェットはホーム画面の長押しから足せます。"))
        #expect(file.appReview?.reason == "ウィジェットの足し方を審査の人に伝える案です")
        // ビルドがまだ無いので、人の番にしない
        // 撮り方の無いリポジトリはスクショを撮らない
        #expect(file.screenshots?.state == .notConfigured)
        #expect(file.builds.isEmpty && file.revision == 3 && !file.awaitsSubmission)
        #expect(await submissionBlockers(watch).isEmpty)
        // App Store Connect には書かない
        #expect(appStore.state.withLock { $0.writes }.isEmpty)
    }

    @Test func recordsBuildsUploadedAfterTheBranch() async throws {
        try await startRelease()
        let watch = watch()
        await watch.refresh()
        // release ブランチを作る前に上げたビルドは使わない
        appStore.state.withLock { $0.builds = [build("44", minutesFromNow: -10)] }
        clock.advance(minutes: 30)
        await watch.refresh()
        #expect(try await submission().builds.isEmpty)

        appStore.state.withLock { state in
            state.builds = [
                build("46", platform: .macOS, minutesFromNow: 25), build("45", minutesFromNow: 20), build("44", minutesFromNow: -10)
            ]
        }
        clock.advance(minutes: 10)
        await watch.refresh()
        let file = try await submission()
        #expect(file.builds.map(\.build) == ["46", "45"])
        #expect(file.revision == 4 && file.awaitsSubmission)
        let blockers = await submissionBlockers(watch)
        #expect(blockers.map(\.reason) == [.submissionReady])
        #expect(blockers.first?.key == "submission/shariverse/oshikatsu-countdown-ios/1.2.0/ready/4")
        #expect(blockers.first?.scope == .submission(Self.repo, Self.next))

        // 同じビルドなら、版を上げない
        clock.advance(minutes: 10)
        await watch.refresh()
        #expect(try await submission().revision == 4)
    }

    @Test func doesNotDraftWhatsNewForTheFirstVersion() async throws {
        try await startRelease()
        appStore.state.withLock { $0.versions = [] }
        await watch().refresh()
        let file = try await submission()
        #expect(file.whatsNew?.drafts.isEmpty == true)
        #expect(whatsNewDrafter.materials.withLock { $0 }.isEmpty)
        // 掲載文も案を書かない（App Store Connect で書く）
        #expect(file.listing?.current.isEmpty == true && file.listing?.drafts.isEmpty == true)
        #expect(listingDrafter.materials.withLock { $0 }.isEmpty)
    }

    @Test func keepsListingWhenNothingToChange() async throws {
        try await startRelease()
        listingDrafter.proposal.withLock { $0 = ListingProposal(drafts: [], reason: "使う人に見える変更が無いので変えません") }
        await watch().refresh()
        let file = try await submission()
        let listing = try #require(file.listing)
        #expect(listing.drafts.isEmpty && listing.reason == "使う人に見える変更が無いので変えません")
        #expect(listing.current.count == 2)
        // App Review の情報も変えない（理由が無ければ決まった文）
        #expect(file.appReview?.draft == nil && file.appReview?.reason == "審査する人に伝えることは変わらないので、変えません")
    }

    @Test func doesNotDraftListingAfterSubmission() async throws {
        try await startRelease()
        var file = SubmissionHandlersTests.started()
        file.branch = .init(name: "release/1.2.0", commit: Self.developHead, created: true, at: file.createdAt)
        file.whatsNew = .init(drafts: [.init(locale: "ja", text: "・下書き")], draftedAt: file.createdAt)
        file.submit = .init(
            approval: file.start!.approval,
            at: file.createdAt,
            builds: [.init(platform: .iOS, build: "45")],
            whatsNew: [.init(locale: "ja", text: "・下書き")],
            releaseType: .afterApproval
        )
        await store.put(StatePath.submission(Self.repo, Self.next), data: try StateFileCoder.encode(file))
        await watch().refresh()
        #expect(try await submission().listing == nil)
        #expect(listingDrafter.materials.withLock { $0 }.isEmpty)
    }

    @Test func asksHumanToAnswerExportCompliance() async throws {
        try await startRelease()
        // release ブランチを作った（30 分後）後に上げたビルド
        appStore.state.withLock { $0.builds = [build("45", minutesFromNow: 40, answered: false)] }
        clock.advance(minutes: 30)
        let watch = watch()
        await watch.refresh()
        let file = try await submission()
        #expect(file.builds.isEmpty)
        #expect(file.problem?.step == .builds && file.problem?.needsHuman == true)
        #expect(await submissionBlockers(watch).map(\.reason) == [.submissionProblem(.builds)])
    }

    @Test func leavesAbandonedReleasesAlone() async throws {
        try await startRelease()
        var file = SubmissionHandlersTests.started()
        file.end = .init(reason: .abandoned, at: file.createdAt, approval: file.start?.approval)
        await store.put(StatePath.submission(Self.repo, Self.next), data: try StateFileCoder.encode(file))
        await watch().refresh()
        #expect(try await submission().branch == nil)
        #expect(hosting.state.withLock { $0.branches["release/1.2.0"] } == nil)
    }
}
