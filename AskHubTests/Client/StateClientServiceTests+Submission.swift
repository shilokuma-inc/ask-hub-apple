@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// リリースを始めてから配信まで: 準備と審査の進み具合を出し、審査に出す・配信するを「あなたの番」に出し、操作を見たものに結びつけて送る
extension StateClientServiceTests {
    private static let submissionDirectory = "repos/\(repo)/submissions"

    /// 1.2.0 は準備がそろって審査に出すのを待っている。1.1.0 は配信した
    static func submissionFiles(extra: [String: String] = [:]) -> [String: String] {
        let key = String(repeating: "k", count: 43)
        let commit = String(repeating: "b", count: 40)
        let ready = """
            {"v":1,"repo":"\(repo)","version":"1.2.0","origin":"askhub",
             "start":{"approval":{"keyId":"\(key)","nonce":"01JCN0NCE00000000000000009"},"at":"2027-01-20T01:00:00Z"},
             "branch":{"name":"release/1.2.0","commit":"\(commit)","created":true,"at":"2027-01-20T01:01:00Z"},
             "nextVersion":{"version":"1.3.0","state":"merged","pullRequest":180,"at":"2027-01-20T01:20:00Z"},
             "builds":[{"platform":"iOS","build":"45","uploadedAt":"2027-01-20T01:40:00Z"}],
             "whatsNew":{"drafts":[{"locale":"ja","text":"・速くなりました"},{"locale":"en-US","text":"- Faster"}],
                         "draftedAt":"2027-01-20T01:05:00Z"},
             "listing":{"current":[{"locale":"ja","description":"素数のクイズ","keywords":"素数,クイズ"},
                                   {"locale":"en-US","description":"A prime quiz","promotionalText":"New!"}],
                        "drafts":[{"locale":"ja","keywords":"素数,クイズ,タイムアタック"}],
                        "reason":"タイムアタックを足したので、キーワードに入れる案です","draftedAt":"2027-01-20T01:06:00Z"},
             "appReview":{"current":{"notes":"ログインは不要です。","demoAccountRequired":false},
                          "draft":{"notes":"ログインは不要です。タイムアタックは右上のボタンから始めます。"},
                          "reason":"タイムアタックの始め方を伝える案です","draftedAt":"2027-01-20T01:06:00Z"},
             "screenshots":{"state":"captured","commit":"\(commit)","startedAt":"2027-01-20T01:10:00Z","finishedAt":"2027-01-20T01:30:00Z",
                            "sets":[{"displayType":"IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE","locale":"ja","removed":0,"shots":[
                              {"index":1,"name":"01","changed":false},
                              {"index":2,"name":"02","changed":true,
                               "preview":"repos/\(repo)/store-screenshots/1.2.0/IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE/ja/2.jpg",
                               "before":"https://is1-ssl.mzstatic.com/a/2.png","area":{"x":0.1,"y":0.2,"width":0.5,"height":0.3}}]}],
                            "skipped":[]},
             "revision":2,"review":[],"createdAt":"2027-01-20T01:00:00Z","updatedAt":"2027-01-20T01:40:00Z"}
            """
        return releaseFiles(extra: ["\(submissionDirectory)/1.2.0.json": ready].merging(extra) { $1 })
    }

    private var submissionRepositoryID: TargetRepository.ID { Self.repo.lowercased() }

    private var request: Submission.SubmitRequest {
        Submission.SubmitRequest(
            revision: 2,
            builds: [.init(platform: "iOS", build: "45")],
            whatsNew: [.init(locale: "ja", text: " ・速くなりました（直した）\n"), .init(locale: "en-US", text: "- Faster")],
            releaseType: .manual
        )
    }

    @Test
    func readsSubmissionAwaitingReview() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        let submission = try #require(snapshot.submission(Submission.id(submissionRepositoryID, "1.2.0")))
        #expect(submission.startedInAskHub && submission.awaitsSubmission && submission.canAbandon)
        #expect(submission.buildSummary == "iOS (45)")
        #expect(submission.drafts?.map(\.locale) == ["ja", "en-US"])
        #expect(submission.listing?.current.map(\.locale) == ["ja", "en-US"])
        #expect(submission.listing?.drafts == [.init(locale: "ja", values: [.keywords: "素数,クイズ,タイムアタック"])])
        #expect(submission.steps.map(\.state) == [.done, .done, .done, .done, .done, .done, .waitingHuman, .working])
        // 次のリリースは、この版が終わるまで始められない。配信した版（1.1.0）より大きくない版も始められない
        #expect(!fixture.service.supports(.startRelease(repositoryID: submissionRepositoryID, version: "1.3.0")))
        let items = InboxBuilder.items(from: snapshot, now: now).filter { $0.kind == .submissionReady }
        #expect(items.first?.route == .submission(repositoryID: submissionRepositoryID, version: "1.2.0"))
        #expect(snapshot.suggestedReleaseVersion(of: submissionRepositoryID) == "1.2.0")
    }

    @Test
    func submittingSendsWhatHumanSaw() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let intent = HumanIntent.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: request)
        #expect(service.supports(intent))
        #expect(!service.supports(.distributeRelease(repositoryID: submissionRepositoryID, version: "1.2.0")))
        #expect(!service.supports(.withdrawSubmission(repositoryID: submissionRepositoryID, version: "1.2.0")))
        try await service.perform(intent)

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == SubmitForReviewIntent.kind)
        #expect(envelope.target == IntentEnvelope.Target(type: "submission", id: "1.2.0"))
        #expect(envelope.targetVersion == "2")
        let submit = try SubmitForReviewIntent(envelope: envelope)
        #expect(submit.releaseType == .manual)
        #expect(submit.whatsNew == [.init(locale: "ja", text: "・速くなりました（直した）"), .init(locale: "en-US", text: "- Faster")])

        // 送った後は、受け付けを待っている間として出し、あなたの番から外す
        let sent = try await service.fetchSnapshot()
        let submission = try #require(sent.submission(Submission.id(submissionRepositoryID, "1.2.0")))
        #expect(submission.sending == .submit)
        #expect(!service.supports(intent))
        #expect(!InboxBuilder.items(from: sent, now: now).contains { $0.kind == .submissionReady })
        #expect(sent.sentIntents.first?.title == "審査に出す（sample-ios 1.2.0）")
        #expect(sent.sentIntents.first?.target == .submission(repositoryID: submissionRepositoryID, version: "1.2.0"))
    }

    @Test
    func sendsOnlyChangedListingFields() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        _ = try await fixture.service.fetchSnapshot()
        var withListing = request
        withListing.listing = [
            // 「変える」にした欄は、今の文と同じでも送る（比べて省くのは司令塔）。前後の空白は除く
            .init(locale: "ja", values: [.description: "素数のクイズ", .keywords: " 素数,クイズ,タイムアタック\n"]),
            // プロモーションテキストは空にできる
            .init(locale: "en-US", values: [.promotionalText: ""])
        ]
        try await fixture.service.perform(.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: withListing))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let submit = try SubmitForReviewIntent(envelope: envelope)
        #expect(submit.listing == [
            ListingText(locale: "ja", description: "素数のクイズ", keywords: "素数,クイズ,タイムアタック"),
            ListingText(locale: "en-US", promotionalText: "")
        ])
    }

    @Test
    func sendsScreenshotDecisionForTheCapturedShots() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        let screenshots = try #require(snapshot.submission(Submission.id(submissionRepositoryID, "1.2.0"))?.screenshots)
        let shot = try #require(screenshots.changedSets.first?.changedShots.first)
        #expect(shot.after == .stored("repos/\(Self.repo)/store-screenshots/1.2.0/IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE/ja/2.jpg"))
        #expect(shot.before == .remote(URL(string: "https://is1-ssl.mzstatic.com/a/2.png")!))
        var withScreenshots = request
        withScreenshots.screenshotKeep = [.init(displayType: "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", locale: "ja", index: 2)]
        let submitting = HumanIntent.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: withScreenshots)
        try await fixture.service.perform(submitting)
        let submit = try SubmitForReviewIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        #expect(submit.screenshots?.commit == String(repeating: "b", count: 40))
        #expect(submit.screenshots?.keep == [.init(displayType: "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", locale: "ja", index: 2)])
        // 差の無い画面は前のままにできない（取り直しを促す）。送った後の「受け付けを待っている」で断られないよう、取り直す
        let fresh = try makeService(files: Self.submissionFiles())
        _ = try await fresh.service.fetchSnapshot()
        var unchanged = request
        unchanged.screenshotKeep = [.init(displayType: "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", locale: "ja", index: 1)]
        let intent = HumanIntent.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: unchanged)
        #expect(fresh.service.supports(intent))
        await #expect(throws: ClientServiceError.self) { try await fresh.service.perform(intent) }
    }

    @Test
    func retakingSendsTheChosenSets() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        _ = try await fixture.service.fetchSnapshot()
        let intent = HumanIntent.retakeScreenshots(
            repositoryID: submissionRepositoryID, version: "1.2.0", displayTypes: ["IPHONE_DUO_PROFILE"], locales: ["ja"]
        )
        #expect(fixture.service.supports(intent))
        try await fixture.service.perform(intent)
        let retake = try RetakeScreenshotsIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        #expect(retake.displayTypes == ["IPHONE_DUO_PROFILE"] && retake.locales == ["ja"])
        // 送った後は受け付けを待っている間として出し、続けては送れない
        let sent = try await fixture.service.fetchSnapshot()
        #expect(sent.submission(Submission.id(submissionRepositoryID, "1.2.0"))?.sending == .retake)
        #expect(!fixture.service.supports(intent))
    }

    @Test
    func sendsAppReviewWithoutPassword() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        let review = try #require(snapshot.submission(Submission.id(submissionRepositoryID, "1.2.0"))?.appReview)
        #expect(review.draft?.notes == "ログインは不要です。タイムアタックは右上のボタンから始めます。")
        var withReview = request
        withReview.appReview = .init(notes: " ログインは不要です。 ", demoAccountRequired: true, demoAccountName: "review@example.com")
        try await fixture.service.perform(.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: withReview))
        let submit = try SubmitForReviewIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        let expected = ReviewInformation(notes: "ログインは不要です。", demoAccountRequired: true, demoAccountName: "review@example.com")
        #expect(submit.appReview == expected)
        // 長すぎるメモ・改行のある名前は送らない（送った後の「受け付けを待っている」で断られないよう、値ごとに取り直す）
        for invalid: Submission.ReviewInfo in [.init(notes: String(repeating: "審", count: 1_400)), .init(demoAccountName: "a\nb")] {
            let fresh = try makeService(files: Self.submissionFiles())
            _ = try await fresh.service.fetchSnapshot()
            var changed = request
            changed.appReview = invalid
            let intent = HumanIntent.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: changed)
            #expect(fresh.service.supports(intent))
            await #expect(throws: ClientServiceError.self) { try await fresh.service.perform(intent) }
        }
    }

    @Test
    func refusesListingThatCannotBeSent() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        _ = try await fixture.service.fetchSnapshot()
        // 配信中の版に無い言語・空の説明文・100 バイトを超えるキーワード
        let invalid: [[Submission.ListingTexts]] = [
            [.init(locale: "fr", values: [.keywords: "premier"])],
            [.init(locale: "ja", values: [.description: "  "])],
            [.init(locale: "ja", values: [.keywords: String(repeating: "素数,", count: 30)])]
        ]
        for listing in invalid {
            var changed = request
            changed.listing = listing
            let intent = HumanIntent.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: changed)
            await #expect(throws: ClientServiceError.self) { try await fixture.service.perform(intent) }
        }
    }

    @Test
    func refusesStaleRevisionAndMismatchedLocales() async throws {
        let fixture = try makeService(files: Self.submissionFiles())
        _ = try await fixture.service.fetchSnapshot()
        var stale = request
        stale.revision = 1
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: stale))
        }
        var missing = request
        missing.whatsNew = [.init(locale: "ja", text: "本文")]
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.submitForReview(repositoryID: submissionRepositoryID, version: "1.2.0", request: missing))
        }
    }

    @Test
    func startsReleaseAndShowsItUntilTheCommanderRecordsIt() async throws {
        let fixture = try makeService(files: Self.releaseFiles())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        // 配信した版（1.1.0）より大きい版だけ始められる
        #expect(!service.supports(.startRelease(repositoryID: submissionRepositoryID, version: "1.1.0")))
        let intent = HumanIntent.startRelease(repositoryID: submissionRepositoryID, version: "1.2.0")
        #expect(service.supports(intent))
        try await service.perform(intent)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == StartReleaseIntent.kind)
        #expect(envelope.payload == ["version": .string("1.2.0")])
        #expect(envelope.target == nil)

        let sent = try await service.fetchSnapshot()
        let placeholder = try #require(sent.submission(Submission.id(submissionRepositoryID, "1.2.0")))
        #expect(placeholder.sending == .start)
        #expect(!service.supports(.startRelease(repositoryID: submissionRepositoryID, version: "1.3.0")))
        #expect(sent.sentIntents.first?.target == .submission(repositoryID: submissionRepositoryID, version: "1.2.0"))
    }
}
