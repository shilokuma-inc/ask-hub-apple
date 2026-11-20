@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 配信中の版のプロモーションテキスト: 見回りで今の文を読み、人が直した中身を App Store Connect に書く
extension ReleaseWatchTests {
    /// 配信中の 1.1.0（iOS）の掲載文
    func livePromotionalText(ja: String? = "推しの予定を数えよう", english: String? = nil) {
        live()
        appStore.state.withLock { state in
            state.localizations["live-0"] = [
                AppStoreLocalization(id: "l-ja", locale: "ja", whatsNew: nil, listing: .init(locale: "ja", promotionalText: ja)),
                AppStoreLocalization(id: "l-en", locale: "en-US", whatsNew: nil, listing: .init(locale: "en-US", promotionalText: english))
            ]
        }
    }

    func request(_ texts: [LocalizedText], nonce: String = "01JCN0NCE00000000000000007") -> ReleaseFile.PromotionalTextRequest {
        let reference = IntentReference(keyId: SubmissionHandlersTests.keyID, nonce: ULID(rawValue: nonce)!)
        return .init(approval: reference, at: Timestamp(Self.now), texts: texts)
    }

    @Test func readsPromotionalTextOfTheLiveVersion() async throws {
        try await addRepository()
        livePromotionalText()
        let watch = watch()
        await watch.refresh()
        let promotionalText = try #require(try await release().promotionalText)
        // 空の言語は空の文字列で持つ
        #expect(promotionalText.current == [.init(locale: "ja", text: "推しの予定を数えよう"), .init(locale: "en-US", text: "")])
        #expect(promotionalText.readAt == Timestamp(Self.now) && promotionalText.request == nil)

        // 変わっていなければ書き直さない。変わったら書き直す
        clock.advance(minutes: 31)
        await watch.refresh()
        #expect(try await release().promotionalText?.readAt == Timestamp(Self.now))
        appStore.state.withLock { $0.localizations["live-0"]?[1].listing.promotionalText = "Count down" }
        clock.advance(minutes: 31)
        await watch.refresh()
        #expect(try await release().promotionalText?.current.last?.text == "Count down")
    }

    @Test func writesRequestedPromotionalTextOnce() async throws {
        try await addRepository()
        livePromotionalText()
        let watch = watch()
        await watch.refresh()
        var file = try await release()
        // 日本語は今の文と同じなので書かない。英語は空から書く
        let texts = [LocalizedText(locale: "ja", text: "推しの予定を数えよう"), LocalizedText(locale: "en-US", text: "New widgets")]
        file.promotionalText?.request = request(texts)
        try await put(file)
        let writesBefore = appStore.state.withLock { $0.writes }
        await watch.refresh()
        let writes = appStore.state.withLock { $0.writes }.dropFirst(writesBefore.count)
        #expect(Array(writes) == ["updateListing l-en promotionalText=New widgets"])
        let done = try #require(try await release().promotionalText)
        #expect(done.request?.doneAt == Timestamp(Self.now) && done.request?.failure == nil)
        #expect(done.current.last?.text == "New widgets")
        // 書き終えたら、もう一度は書かない
        await watch.refresh()
        #expect(appStore.state.withLock { $0.writes }.count == writesBefore.count + 1)
    }

    @Test func recordsRefusalAndStops() async throws {
        try await addRepository()
        livePromotionalText()
        let watch = watch()
        await watch.refresh()
        var file = try await release()
        file.promotionalText?.request = request([.init(locale: "en-US", text: "New widgets")])
        try await put(file)
        appStore.state.withLock { $0.refusal = .refused(status: 409, detail: "The promotional text can't be edited.") }
        await watch.refresh()
        let failure = try #require(try await release().promotionalText?.request?.failure)
        #expect(failure.contains("The promotional text can't be edited."))
        // 断られたら、新しく押すまで書き直さない
        appStore.state.withLock { $0.refusal = nil }
        await watch.refresh()
        #expect(appStore.state.withLock { $0.writes }.isEmpty)
    }
}

/// 配信中の版のプロモーションテキストを直す人の意図（`UpdatePromotionalTextHandler`）
extension SubmissionHandlersTests {
    func promotionalEnvelope(
        _ texts: [LocalizedText],
        version: String = "1.1.0",
        nonce: String = "01JCN0NCE00000000000000008"
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: UpdatePromotionalTextIntent.kind,
            repo: ReleaseWatchTests.repo,
            target: .init(type: "release", id: version),
            targetVersion: nil,
            payload: UpdatePromotionalTextIntent.payload(texts: texts),
            issuedAt: Timestamp(ReleaseWatchTests.now),
            nonce: ULID(rawValue: nonce)!,
            keyId: Self.keyID
        )
    }

    func putRelease(_ version: String, promotionalText: ReleaseFile.PromotionalText?) async throws {
        let now = Timestamp(ReleaseWatchTests.now)
        let release = MarketingVersion(rawValue: version)!
        let file = ReleaseFile(
            repo: ReleaseWatchTests.repo,
            version: release,
            platforms: [.init(platform: .iOS, build: "31", detectedAt: now)],
            promotionalText: promotionalText,
            detectedAt: now,
            updatedAt: now
        )
        await store.put(StatePath.release(ReleaseWatchTests.repo, release), data: try StateFileCoder.encode(file))
    }

    func releaseFile(_ version: String) async throws -> ReleaseFile? {
        let path = StatePath.release(ReleaseWatchTests.repo, MarketingVersion(rawValue: version)!)
        guard let data = await store.data(at: path) else { return nil }
        return try StateFileCoder.decode(ReleaseFile.self, from: data)
    }

    @Test func recordsPromotionalTextRequestForTheLiveVersion() async throws {
        let current = [LocalizedText(locale: "ja", text: "推しの予定を数えよう")]
        let handler = UpdatePromotionalTextHandler()
        // まだ今の文を読んでいない
        try await putRelease("1.1.0", promotionalText: nil)
        #expect(try await handler.handle(promotionalEnvelope([.init(locale: "ja", text: "新しい")]), in: context) != .accept)

        try await putRelease("1.1.0", promotionalText: .init(current: current, readAt: Timestamp(ReleaseWatchTests.now)))
        // 配信中の版に無い言語は断る
        #expect(try await handler.handle(promotionalEnvelope([.init(locale: "fr", text: "Nouveau")]), in: context) != .accept)
        let texts = [LocalizedText(locale: "ja", text: "")]
        #expect(try await handler.handle(promotionalEnvelope(texts), in: context) == .accept)
        let request = try #require(try await releaseFile("1.1.0")?.promotionalText?.request)
        #expect(request.texts == texts && request.isPending)
        // やり直しは受け付ける
        #expect(try await handler.handle(promotionalEnvelope(texts), in: context) == .accept)

        // もっと新しい版を配信したら、古い版は断る
        try await putRelease("1.2.0", promotionalText: .init(current: current, readAt: Timestamp(ReleaseWatchTests.now)))
        let old = promotionalEnvelope(texts, nonce: "01JCN0NCE00000000000000009")
        #expect(try await handler.handle(old, in: context) != .accept)
    }
}
