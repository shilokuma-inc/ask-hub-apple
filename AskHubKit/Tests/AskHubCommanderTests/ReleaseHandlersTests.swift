@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// リリース文を確かめて GitHub Release を公開する人の意図（`PublishGitHubReleaseHandler`）
struct PublishGitHubReleaseHandlerTests {
    static let keyID = KeyID(rawValue: String(repeating: "k", count: 43))!
    let store = InMemoryStateStore()

    var context: CommanderContext {
        CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { ReleaseWatchTests.now }
    }

    func envelope(notesVersion: String = "1", nonce: String = "01JCN0NCE00000000000000001", notes: String = "## 直した本文") -> IntentEnvelope {
        IntentEnvelope(
            kind: "publishGitHubRelease",
            repo: ReleaseWatchTests.repo,
            target: .init(type: "release", id: "1.1.0"),
            targetVersion: notesVersion,
            payload: ["notes": .string(notes)],
            issuedAt: Timestamp(ReleaseWatchTests.now),
            nonce: ULID(rawValue: nonce)!,
            keyId: Self.keyID
        )
    }

    func put(notes: ReleaseFile.Notes?, release: ReleaseFile.GitHubRelease? = nil) async throws {
        let now = Timestamp(ReleaseWatchTests.now)
        let file = ReleaseFile(
            repo: ReleaseWatchTests.repo,
            version: ReleaseWatchTests.version,
            platforms: [.init(platform: .iOS, build: "31", detectedAt: now)],
            commit: .init(sha: ReleaseWatchTests.released, source: .existingTag),
            tag: .init(name: "v1.1.0", created: false, at: now),
            notes: notes,
            githubRelease: release,
            detectedAt: now,
            updatedAt: now
        )
        await store.put(StatePath.release(ReleaseWatchTests.repo, ReleaseWatchTests.version), data: try StateFileCoder.encode(file))
    }

    func file() async throws -> ReleaseFile {
        let data = try #require(await store.data(at: StatePath.release(ReleaseWatchTests.repo, ReleaseWatchTests.version)))
        return try StateFileCoder.decode(ReleaseFile.self, from: data)
    }

    static let draft = ReleaseFile.Notes(version: 1, draft: "## 下書き", draftedAt: Timestamp(ReleaseWatchTests.now))

    @Test func copiesConfirmedNotesAndAcceptsRetry() async throws {
        try await put(notes: Self.draft)
        let handler = PublishGitHubReleaseHandler()
        #expect(try await handler.handle(envelope(), in: context) == .accept)
        let confirmed = try #require(try await file().notes?.confirmed)
        #expect(confirmed.text == "## 直した本文")
        #expect(confirmed.approval.nonce.rawValue == "01JCN0NCE00000000000000001")
        // 同じ意図のやり直しは受け付ける。別の意図は断る（もう受け付けている）
        #expect(try await handler.handle(envelope(), in: context) == .accept)
        if case .reject = try await handler.handle(envelope(nonce: "01JCN0NCE00000000000000002"), in: context) {} else {
            Issue.record("2 つ目の公開を受け付けた")
        }
    }

    @Test func rejectsStaleOrMissingNotesAndPublishedRelease() async throws {
        let handler = PublishGitHubReleaseHandler()
        // 記録が無い
        if case .reject = try await handler.handle(envelope(), in: context) {} else { Issue.record("記録が無いのに受け付けた") }
        // 下書きがまだ無い
        try await put(notes: nil)
        if case .reject = try await handler.handle(envelope(), in: context) {} else { Issue.record("下書きが無いのに受け付けた") }
        // 下書きが作り直された
        try await put(notes: .init(version: 2, draft: "## 作り直した", draftedAt: Timestamp(ReleaseWatchTests.now)))
        if case .reject = try await handler.handle(envelope(notesVersion: "1"), in: context) {} else { Issue.record("古い下書きへの公開を受け付けた") }
        // もう公開している
        try await put(notes: Self.draft, release: .init(url: "https://github.com/x/y/releases/tag/v1.1.0", created: false, at: Timestamp(ReleaseWatchTests.now)))
        if case .reject = try await handler.handle(envelope(), in: context) {} else { Issue.record("公開した版への公開を受け付けた") }
        #expect(try await file().notes?.confirmed == nil)
    }
}
