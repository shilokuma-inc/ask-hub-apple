@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// hotfix を始める意図（`StartReleaseHandler` の hotfix）と、進行中のリリースの一時停止
extension SubmissionHandlersTests {
    func hotfixEnvelope(_ version: String, suspend: String? = nil, nonce: String = "01JCN0NCE0000000000000000H") -> IntentEnvelope {
        var payload: [String: JSONValue] = ["version": .string(version), "hotfix": .bool(true)]
        if let suspend { payload["suspend"] = .string(suspend) }
        return IntentEnvelope(
            kind: StartReleaseIntent.kind,
            repo: ReleaseWatchTests.repo,
            payload: payload,
            issuedAt: Timestamp(ReleaseWatchTests.now),
            nonce: ULID(rawValue: nonce)!,
            keyId: Self.keyID
        )
    }

    @Test func startsHotfixOnlyAsNextPatchOfReleasedVersion() async throws {
        try await addRepository()
        try await released("1.1.0")
        let handler = StartReleaseHandler()
        #expect(try await handler.handle(hotfixEnvelope("1.2.0"), in: context)
            == .reject("hotfix の版は、配信中の版（1.1.0）の次のパッチ（1.1.1）にする"))
        #expect(try await handler.handle(hotfixEnvelope("1.1.1"), in: context) == .accept)
        let hotfix = try #require(try await file(MarketingVersion(rawValue: "1.1.1")!))
        #expect(hotfix.hotfix == .init(from: MarketingVersion(rawValue: "1.1.0")!))
        #expect(hotfix.appStoreVersions?.isEmpty == true)
        // やり直しは受け付ける
        #expect(try await handler.handle(hotfixEnvelope("1.1.1"), in: context) == .accept)
    }

    @Test func hotfixSuspendsOpenReleaseOnlyAfterConfirmation() async throws {
        try await addRepository()
        try await released("1.1.0")
        var open = Self.prepared()
        open.submit = .init(
            approval: open.start!.approval,
            at: open.createdAt,
            builds: [.init(platform: .iOS, build: "45")],
            whatsNew: [],
            releaseType: .afterApproval
        )
        open.review = [.init(platform: .iOS, state: .inReview, since: open.createdAt, submittedAt: open.createdAt)]
        try await put(open)
        let handler = StartReleaseHandler()
        // 一時停止を確かめていなければ断る
        #expect(try await handler.handle(hotfixEnvelope("1.1.1"), in: context)
            == .reject("進行中の 1.2.0 のリリースを一時停止することを確かめてから始める（取り直して送り直す）"))
        #expect(try await handler.handle(hotfixEnvelope("1.1.1", suspend: "1.2.0"), in: context) == .accept)
        let suspended = try #require(try await file())
        #expect(suspended.isSuspended && suspended.suspension?.by == MarketingVersion(rawValue: "1.1.1"))
        // 審査中なので、取り下げも頼む。一時停止の間は審査に出せない
        #expect(suspended.withdrawal != nil && !suspended.awaitsSubmission)
        let hotfix = try #require(try await file(MarketingVersion(rawValue: "1.1.1")!))
        #expect(hotfix.hotfix?.suspended == Self.next)
    }

    @Test func hotfixRefusesToSuspendApprovedRelease() async throws {
        try await addRepository()
        try await released("1.1.0")
        var open = Self.prepared()
        open.review = [.init(platform: .iOS, state: .pendingDeveloperRelease, since: open.createdAt, submittedAt: open.createdAt)]
        try await put(open)
        let reason = "1.2.0 は審査に通っている（API で取り下げられない）。配信するか、App Store Connect で取り下げてから hotfix を始める"
        #expect(try await StartReleaseHandler().handle(hotfixEnvelope("1.1.1", suspend: "1.2.0"), in: context) == .reject(reason))
        #expect(try await file()?.suspension == nil)
    }
}

/// hotfix の準備・取り込みと、一時停止したリリースの再開（`ReleaseWatch`）
extension ReleaseWatchTests {
    /// 配信中の 1.1.0 を直す hotfix（記録の版は 1.2.0 で代える）
    func startHotfix(suspended: MarketingVersion? = nil) async throws {
        try await startRelease()
        var file = SubmissionHandlersTests.started()
        file.hotfix = .init(from: Self.version, suspended: suspended)
        file.appStoreVersions = []
        try await putSubmission(file)
        hosting.state.withLock { $0.tags["v1.1.0"] = Self.released }
        sources.state.withLock { state in
            state.snapshot.files = [.init(path: "Configs/Project.xcconfig", content: "MARKETING_VERSION = 1.1.0\n")]
        }
    }

    @Test func hotfixBranchesFromTagAndBumpsReleaseBranch() async throws {
        try await startHotfix()
        await watch().refresh()
        let file = try await submission()
        // release ブランチは配信中の版のタグから作り、develop には触れない
        #expect(file.branch?.commit == Self.released)
        #expect(hosting.state.withLock { $0.branches["release/1.2.0"] } == Self.released)
        let committed = try #require(hosting.state.withLock { $0.committed.first { $0.branch == "askhub/hotfix-version-1.2.0" } })
        #expect(committed.files == ["Configs/Project.xcconfig": "MARKETING_VERSION = 1.2.0\n"])
        let opened = try #require(hosting.state.withLock { $0.opened.first { $0.head == "askhub/hotfix-version-1.2.0" } })
        #expect(opened.base == "release/1.2.0")
        // 直しを入れたビルドが上がるまで、What's New と掲載文の案は書かない
        #expect(file.whatsNew == nil && file.listing == nil)
        #expect(whatsNewDrafter.materials.withLock { $0 }.isEmpty)
    }

    @Test func hotfixTakesOverSlotOfSuspendedRelease() async throws {
        try await startHotfix(suspended: MarketingVersion(rawValue: "1.3.0"))
        appStore.state.withLock { state in
            state.others = [AppStoreVersionInfo(id: "v-1-3-0", platform: .iOS, versionString: "1.3.0", state: .developerRejected)]
        }
        await watch().refresh()
        let file = try await submission()
        #expect(file.appStoreVersions?.map(\.id) == ["v-1-3-0"])
        #expect(appStore.state.withLock { $0.writes }.contains { $0.hasPrefix("updateVersion v-1-3-0 1.2.0") })
    }

    @Test func integratesHotfixIntoDevelopWithVersionRestored() async throws {
        try await addRepository()
        var file = SubmissionHandlersTests.prepared()
        file.hotfix = .init(from: Self.version)
        file.end = .init(reason: .distributed, at: file.createdAt)
        try await putSubmission(file)
        hosting.state.withLock { state in
            state.branches = ["develop": Self.developHead, "release/1.2.0": Self.released, "main": Self.epicMerge]
            state.ahead["develop...release/1.2.0"] = 2
        }
        sources.state.withLock { state in
            state.snapshot.files = [.init(path: "Configs/Project.xcconfig", content: "MARKETING_VERSION = 1.2.0\n")]
        }
        await watch().refresh()
        // develop には、版の行を配信中の版に戻したブランチから取り込む（develop の版を上書きしない）
        let committed = try #require(hosting.state.withLock { $0.committed.first })
        #expect(committed.branch == "askhub/hotfix-1.2.0-into-develop")
        #expect(committed.files == ["Configs/Project.xcconfig": "MARKETING_VERSION = 1.1.0\n"])
        let opened = try #require(hosting.state.withLock { $0.opened.first { $0.base == "develop" } })
        #expect(opened.head == "askhub/hotfix-1.2.0-into-develop")
    }

    @Test func resumesSuspendedReleaseAfterHotfixIsIntegrated() async throws {
        try await addRepository()
        let hotfixVersion = MarketingVersion(rawValue: "1.1.1")!
        var suspended = SubmissionHandlersTests.prepared()
        suspended.suspension = .init(by: hotfixVersion, approval: suspended.start!.approval, at: suspended.createdAt)
        suspended.appStoreVersions = [.init(platform: .iOS, id: "v-1-2-0", at: suspended.createdAt)]
        try await putSubmission(suspended)
        var hotfix = SubmissionHandlersTests.started(hotfixVersion, nonce: "01JCN0NCE0000000000000000H")
        hotfix.hotfix = .init(from: Self.version, suspended: Self.next)
        hotfix.branch = .init(name: "release/1.1.1", commit: Self.released, created: true, at: hotfix.createdAt)
        try await putSubmission(hotfix)
        hosting.state.withLock { $0.branches["release/1.2.0"] = Self.developHead }
        let watch = watch()
        await watch.refresh()
        // hotfix がまだ配信していないので、一時停止のまま（準備を進めない）
        #expect(try await submission().isSuspended)

        hotfix.end = .init(reason: .distributed, at: hotfix.createdAt)
        hotfix.integration = [.init(base: "release/1.2.0", state: .merged, pullRequest: 171, at: hotfix.createdAt)]
        try await putSubmission(hotfix)
        hosting.state.withLock { $0.branches["release/1.2.0"] = Self.epicMerge }
        await watch.refresh()
        let resumed = try await submission()
        #expect(!resumed.isSuspended && resumed.suspension?.resumedAt != nil)
        // 準備を作り直す（release ブランチの今の先頭から数え直し、版の枠も作り直す）
        #expect(resumed.branch?.commit == Self.epicMerge)
        #expect(resumed.revision > suspended.revision)
        #expect(resumed.appStoreVersions?.contains { $0.id == "v-1-2-0" } != true)
    }
}
