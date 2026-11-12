@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// App Store で配信した版: 後作業の進み具合を出し、リリース文の確認を「あなたの番」に出し、公開を下書きの版に結びつけて送る
extension StateClientServiceTests {
    private static let releaseDirectory = "repos/\(repo)/releases"
    private static let commit = String(repeating: "a", count: 40)

    /// 1.1.0 はリリース文の確認待ち（次の版の PR はチェック待ち）、1.0.0 は後作業が済んでいる
    static func releaseFiles(extra: [String: String] = [:]) -> [String: String] {
        let platforms = #"[{"platform":"iOS","build":"31","uploadedAt":"2027-01-14T03:00:00Z","detectedAt":"2027-01-15T06:00:00Z"}]"#
        let waiting = """
            {"v":1,"repo":"\(repo)","version":"1.1.0","platforms":\(platforms),
             "commit":{"sha":"\(commit)","source":"uploadRun","platform":"iOS","build":"31","run":19000000031,"runNumber":31},
             "tag":{"name":"v1.1.0","created":true,"at":"2027-01-15T06:00:05Z"},
             "notes":{"version":2,"previousTag":"v1.0.0","draft":"## 新しい機能\\n- 写真を切り抜けます","draftedAt":"2027-01-15T06:01:00Z"},
             "nextVersion":{"version":"1.2.0","state":"open","pullRequest":170,"at":"2027-01-15T06:00:10Z"},
             "detectedAt":"2027-01-15T06:00:00Z","updatedAt":"2027-01-15T06:01:00Z"}
            """
        let finished = """
            {"v":1,"repo":"\(repo)","version":"1.0.0","platforms":[{"platform":"iOS","build":"12","detectedAt":"2026-12-01T00:00:00Z"}],
             "commit":{"sha":"\(commit)","source":"existingTag"},"tag":{"name":"v1.0.0","created":false,"at":"2026-12-01T00:00:05Z"},
             "githubRelease":{"url":"https://github.com/\(repo)/releases/tag/v1.0.0","created":false,"at":"2026-12-01T00:00:06Z"},
             "nextVersion":{"version":"1.1.0","state":"skipped","at":"2026-12-01T00:00:07Z"},
             "detectedAt":"2026-12-01T00:00:00Z","updatedAt":"2026-12-01T00:00:07Z"}
            """
        let releases = ["\(releaseDirectory)/1.1.0.json": waiting, "\(releaseDirectory)/1.0.0.json": finished]
        return askingEpic(extra: releases.merging(extra) { $1 })
    }

    private var repositoryID: TargetRepository.ID { Self.repo.lowercased() }

    @Test
    func readsReleasesWithTheirPostWork() async throws {
        let fixture = try makeService(files: Self.releaseFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        // 新しい版から並べる
        #expect(snapshot.releases(of: repositoryID).map(\.version) == ["1.1.0", "1.0.0"])
        let waiting = try #require(snapshot.release(Release.id(repositoryID, "1.1.0")))
        #expect(waiting.platformSummary == "iOS (31)")
        #expect(waiting.awaitsNotesReview)
        #expect(waiting.steps.map(\.state) == [.done, .done, .waitingHuman, .working, .working])
        #expect(waiting.nextVersion == .init(version: "1.2.0", state: .open, pullRequest: 170))
        let finished = try #require(snapshot.release(Release.id(repositoryID, "1.0.0")))
        #expect(finished.isFinished && !finished.awaitsNotesReview)
        #expect(finished.commit?.fromExistingTag == true)

        // あなたの番には、リリース文の確認だけを出す（済んだ版は出さない）
        let items = InboxBuilder.items(from: snapshot, now: now).filter { $0.kind == .releaseNotes || $0.kind == .releaseProblem }
        #expect(items.map(\.kind) == [.releaseNotes])
        #expect(items.first?.route == .release(repositoryID: repositoryID, version: "1.1.0"))
        #expect(items.first?.urgency == .blocking)
    }

    @Test
    func publishingSendsNotesBoundToTheDraftVersion() async throws {
        let fixture = try makeService(files: Self.releaseFiles())
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let intent = HumanIntent.publishRelease(repositoryID: repositoryID, version: "1.1.0", notesVersion: 2, notes: " ## 直した本文\n")
        #expect(service.supports(intent))
        // 済んだ版・下書きの無い版には送れない
        #expect(!service.supports(.publishRelease(repositoryID: repositoryID, version: "1.0.0", notesVersion: 1, notes: "x")))
        try await service.perform(intent)

        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(envelope.kind == PublishGitHubReleaseIntent.kind)
        #expect(envelope.repo?.rawValue == Self.repo)
        #expect(envelope.target == IntentEnvelope.Target(type: "release", id: "1.1.0"))
        #expect(envelope.targetVersion == "2")
        #expect(envelope.payload == ["notes": .string("## 直した本文")])

        // 送った後は、受け付けを待っている間として出し、もう一度は送らせない。あなたの番からも外す
        let sent = try await service.fetchSnapshot()
        let release = try #require(sent.release(Release.id(repositoryID, "1.1.0")))
        #expect(release.publish == .sending)
        #expect(!release.awaitsNotesReview)
        #expect(!service.supports(intent))
        #expect(!InboxBuilder.items(from: sent, now: now).contains { $0.kind == .releaseNotes })
        #expect(sent.sentIntents.first?.title == "GitHub Release の公開（sample-ios 1.1.0）")
        #expect(sent.sentIntents.first?.target == .release(repositoryID: repositoryID, version: "1.1.0"))
    }

    @Test
    func refusesStaleDraftVersionAndEmptyNotes() async throws {
        let fixture = try makeService(files: Self.releaseFiles())
        _ = try await fixture.service.fetchSnapshot()
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.publishRelease(repositoryID: repositoryID, version: "1.1.0", notesVersion: 1, notes: "本文"))
        }
        await #expect(throws: ClientServiceError.self) {
            try await fixture.service.perform(.publishRelease(repositoryID: repositoryID, version: "1.1.0", notesVersion: 2, notes: " \n"))
        }
    }

    @Test
    func showsWhyThePublishWasRejected() async throws {
        let fixture = try makeService(files: Self.releaseFiles())
        _ = try await fixture.service.fetchSnapshot()
        try await fixture.service.perform(.publishRelease(repositoryID: repositoryID, version: "1.1.0", notesVersion: 2, notes: "本文"))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let consumed = #"{"v":1,"kind":"publishGitHubRelease","consumedAt":"2027-01-15T08:00:00Z","result":"rejected","#
            + #""reason":"もう公開している"}"#
        await fixture.store.put(StatePath.consumed(device: fixture.key.keyID, nonce: envelope.nonce), data: Data(consumed.utf8))

        let snapshot = try await fixture.service.fetchSnapshot()
        let release = try #require(snapshot.release(Release.id(repositoryID, "1.1.0")))
        #expect(release.publish == .rejected("もう公開している"))
        // 断られたら、もう一度確かめて送れる
        #expect(release.awaitsNotesReview)
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.kind == .releaseNotes })
        #expect(item.detail == "公開を受け付けませんでした: もう公開している")
    }

    @Test
    func listsPostWorkThatNeedsHuman() async throws {
        let problem = """
            {"v":1,"repo":"\(Self.repo)","version":"1.2.0",
             "platforms":[{"platform":"iOS","build":"40","detectedAt":"2027-01-15T07:00:00Z"}],
             "problem":{"step":"commit","message":"ビルド (40) を上げた Upload の実行が見つからない","needsHuman":true,"at":"2027-01-15T07:00:00Z"},
             "detectedAt":"2027-01-15T07:00:00Z","updatedAt":"2027-01-15T07:00:00Z"}
            """
        let fixture = try makeService(files: Self.releaseFiles(extra: ["\(Self.releaseDirectory)/1.2.0.json": problem]))
        let snapshot = try await fixture.service.fetchSnapshot()
        let release = try #require(snapshot.release(Release.id(repositoryID, "1.2.0")))
        #expect(release.needsHuman)
        #expect(release.steps.first?.state == .problem)
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.kind == .releaseProblem })
        #expect(item.title == "配信の後作業を直す: 配信したコミット")
        #expect(item.detail == "ビルド (40) を上げた Upload の実行が見つからない")
    }

    @Test
    func skipsMisplacedReleaseFiles() async throws {
        // 置き場所の版と中身の版が違う
        let moved = try #require(Self.releaseFiles()["\(Self.releaseDirectory)/1.0.0.json"])
        let fixture = try makeService(files: Self.releaseFiles(extra: ["\(Self.releaseDirectory)/0.9.0.json": moved]))
        let snapshot = try await fixture.service.fetchSnapshot()
        #expect(snapshot.releases(of: repositoryID).map(\.version) == ["1.1.0", "1.0.0"])
        #expect(snapshot.sourceFailures.map(\.source) == ["\(Self.releaseDirectory)/0.9.0.json"])
    }
}
