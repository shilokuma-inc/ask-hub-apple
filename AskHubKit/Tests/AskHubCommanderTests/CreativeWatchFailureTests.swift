@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation
import Testing

/// クリエイティブアセットの案: 進められないとき（ワークフローが無い・書き出せない・形の違う画像・Claude が書けない・上限）
extension ReleaseWatchTests {
    @Test func failsCreativeWhenTheWorkflowIsMissing() async throws {
        try await prepareCreative()
        let drafter = FakeCreativeDrafter()
        let watch = creativeWatch(drafter: drafter, originals: temporaryOriginals())
        hosting.workflows.withLock { $0.dispatchReply = .failure(.notFound) }
        _ = try await DraftCreativeAssetsHandler().handle(creativeEnvelope("draftCreativeAssets", revision: 0), in: creativeContext)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure?.contains("app-kit を v1.2.0 以上に広げる") == true)
    }

    @Test func failsCreativeWithTheReasonOfTheRender() async throws {
        try await prepareCreative()
        let drafter = FakeCreativeDrafter()
        let watch = creativeWatch(drafter: drafter, originals: temporaryOriginals())
        try await draftAndDispatch(watch)
        creativeArtifacts(report: #"{"v": 1, "problems": [], "images": [], "failure": "案の形が合いません: locales が空"}"#)
        hosting.workflows.withLock { $0.runs[Self.creativeRun] = creativeRunDetail(status: "completed", conclusion: "failure") }
        clock.advance(minutes: 5)
        await watch.refresh()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure == "書き出せなかった（案の形が合いません: locales が空）")
    }

    @Test func failsCreativeWhenTheImageHasAlpha() async throws {
        try await prepareCreative()
        let drafter = FakeCreativeDrafter()
        let watch = creativeWatch(drafter: drafter, originals: temporaryOriginals())
        try await draftAndDispatch(watch)
        var files = Self.allImages
        files["en-US/search-results.png"] = creativePNG(.searchResults, alpha: true)
        creativeArtifacts(report: Self.cleanReport, files: files)
        hosting.workflows.withLock { $0.runs[Self.creativeRun] = creativeRunDetail(status: "completed", conclusion: "success") }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForTasks()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure?.contains("アルファ") == true)
    }

    @Test func failsCreativeWhenClaudeCannotDraft() async throws {
        try await prepareCreative()
        let drafter = FakeCreativeDrafter()
        drafter.failure.withLock { $0 = ReleaseNotesFailure(message: "AppStore/languages.json が無い", retryable: false) }
        let watch = creativeWatch(drafter: drafter, originals: temporaryOriginals())
        _ = try await DraftCreativeAssetsHandler().handle(creativeEnvelope("draftCreativeAssets", revision: 0), in: creativeContext)
        await watch.refresh()
        await watch.waitForTasks()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure == "AppStore/languages.json が無い")
        #expect(hosting.workflows.withLock { $0.dispatches.isEmpty })
    }

    @Test func failsCreativeWhenTheArtifactHasOtherLocales() async throws {
        try await prepareCreative()
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: temporaryOriginals())
        try await draftAndDispatch(watch)
        var files = Self.allImages
        files["fr-FR/product-page-header.png"] = Self.header
        files["fr-FR/search-results.png"] = Self.search
        creativeArtifacts(report: Self.cleanReport, files: files)
        hosting.workflows.withLock { $0.runs[Self.creativeRun] = creativeRunDetail(status: "completed", conclusion: "success") }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForTasks()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure?.contains("余分: fr-FR") == true)
    }

    /// id の分からない実行を一覧から見つけ直し、それが取り消されていたら取り込まない
    @Test func failsCreativeWhenTheRecoveredRunWasCancelled() async throws {
        try await prepareCreative()
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: temporaryOriginals())
        hosting.workflows.withLock { $0.dispatchReply = .success(nil) }
        _ = try await DraftCreativeAssetsHandler().handle(creativeEnvelope("draftCreativeAssets", revision: 0), in: creativeContext)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
        creativeArtifacts(report: Self.cleanReport, files: Self.allImages)
        hosting.workflows.withLock { $0.dispatchedRuns = [creativeRunDetail(status: "completed", conclusion: "cancelled")] }
        clock.advance(minutes: 5)
        await watch.refresh()
        #expect(try await creativeFile().draft?.run?.id == Self.creativeRun)
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForTasks()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure?.contains("cancelled") == true)
    }

    @Test func failsCreativeWhenTheWorkflowRunsAreMissing() async throws {
        try await prepareCreative()
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: temporaryOriginals())
        hosting.workflows.withLock { $0.dispatchedRunsFailure = .notFound }
        _ = try await DraftCreativeAssetsHandler().handle(creativeEnvelope("draftCreativeAssets", revision: 0), in: creativeContext)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure?.contains("app-kit を v1.2.0 以上に広げる") == true)
    }

    /// 上限に当たったら、GitHub が示した時間がたつまで送らない
    @Test func holdsCreativeDispatchWhileRateLimited() async throws {
        try await prepareCreative()
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: temporaryOriginals())
        hosting.workflows.withLock { $0.dispatchedRunsFailure = .rateLimited(retryAfter: .seconds(900)) }
        _ = try await DraftCreativeAssetsHandler().handle(creativeEnvelope("draftCreativeAssets", revision: 0), in: creativeContext)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
        hosting.workflows.withLock { $0.dispatchedRunsFailure = nil }
        clock.advance(minutes: 10)
        await watch.refresh()
        #expect(hosting.workflows.withLock { $0.dispatches.isEmpty })
        clock.advance(minutes: 6)
        await watch.refresh()
        #expect(hosting.workflows.withLock { $0.dispatches.count } == 1)
    }

    /// 印と寸法は合うのに画像として読めない（壊れた PNG）なら、やり直さずに案を `failed` にする
    @Test func failsCreativeWhenTheImageCannotBeRead() async throws {
        try await prepareCreative()
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: temporaryOriginals())
        try await draftAndDispatch(watch)
        var files = Self.allImages
        files["ja/product-page-header.png"] = Self.pngHeader(width: 3840, height: 1646)
        creativeArtifacts(report: Self.cleanReport, files: files)
        hosting.workflows.withLock { $0.runs[Self.creativeRun] = creativeRunDetail(status: "completed", conclusion: "success") }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForTasks()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure?.contains("見本を作れない") == true)
    }

    /// artifact を読むときに上限に当たったら、GitHub が示した時間がたつまで取り込み直さない
    @Test func holdsCreativeImportWhileRateLimited() async throws {
        try await prepareCreative()
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: temporaryOriginals())
        try await draftAndDispatch(watch)
        creativeArtifacts(report: Self.cleanReport, files: Self.allImages)
        hosting.workflows.withLock { state in
            state.runs[Self.creativeRun] = creativeRunDetail(status: "completed", conclusion: "success")
            state.artifactsFailure = .rateLimited(retryAfter: .seconds(900))
        }
        clock.advance(minutes: 5)
        await watch.refresh()
        await watch.waitForTasks()
        hosting.workflows.withLock { $0.artifactsFailure = nil }
        clock.advance(minutes: 10)
        await watch.refresh()
        await watch.waitForTasks()
        #expect(try await creativeFile().draft?.state == .rendering)
        clock.advance(minutes: 6)
        await watch.refresh()
        await watch.waitForTasks()
        #expect(try await creativeFile().draft?.state == .rendered)
    }

    /// 起動の後に実行の一覧を読めないまま（ワークフローが消された）、打ち切りの時間がたったら案を `failed` にする
    @Test func failsCreativeWhenTheRunCannotBeFoundForHours() async throws {
        try await prepareCreative()
        let watch = creativeWatch(drafter: FakeCreativeDrafter(), originals: temporaryOriginals())
        hosting.workflows.withLock { $0.dispatchReply = .success(nil) }
        _ = try await DraftCreativeAssetsHandler().handle(creativeEnvelope("draftCreativeAssets", revision: 0), in: creativeContext)
        await watch.refresh()
        await watch.waitForTasks()
        await watch.waitForRefresh()
        hosting.workflows.withLock { $0.dispatchedRunsFailure = .notFound }
        clock.advance(minutes: 5)
        await watch.refresh()
        #expect(try await creativeFile().draft?.state == .rendering)
        clock.advance(minutes: 3 * 60)
        await watch.refresh()
        let draft = try #require(try await creativeFile().draft)
        #expect(draft.state == .failed && draft.failure?.contains("書き出しの実行を探せない") == true)
    }

    /// 1 つの鍵で読めなくても、ほかの鍵でアプリを探す。どの鍵でも見つからなければ、読めなかった鍵の失敗を投げる
    @Test func looksForTheAppWithTheOtherKeys() async throws {
        try await prepareCreative()
        let revoked = FakeAppStore()
        revoked.state.withLock { $0.appsFailure = .unauthorized(status: 401) }
        let watch = CreativeWatch(
            context: creativeContext,
            stores: [revoked, appStore],
            sources: sources,
            hosting: hosting,
            artifacts: FakeCreativeExtractor(),
            drafter: FakeCreativeDrafter(),
            originals: temporaryOriginals(),
            log: { _ in }
        )
        #expect(try await watch.app(of: Self.repo, base: "develop")?.store == 1)
        let alone = CreativeWatch(
            context: creativeContext,
            stores: [revoked],
            sources: sources,
            hosting: hosting,
            artifacts: FakeCreativeExtractor(),
            drafter: FakeCreativeDrafter(),
            originals: temporaryOriginals(),
            log: { _ in }
        )
        await #expect(throws: ReleaseStepProblem.self) { try await alone.app(of: Self.repo, base: "develop") }
        // 待てば直る失敗（503）と人が直す失敗（401）が両方あれば、鍵の順によらず待てば直る失敗を投げる（自動でやり直す）
        let unavailable = FakeAppStore()
        unavailable.state.withLock { $0.appsFailure = .unavailable("503") }
        for stores in [[unavailable, revoked], [revoked, unavailable]] {
            let both = CreativeWatch(
                context: creativeContext,
                stores: stores,
                sources: sources,
                hosting: hosting,
                artifacts: FakeCreativeExtractor(),
                drafter: FakeCreativeDrafter(),
                originals: temporaryOriginals(),
                log: { _ in }
            )
            do {
                _ = try await both.app(of: Self.repo, base: "develop")
                Issue.record("投げていない")
            } catch let problem as ReleaseStepProblem {
                #expect(!problem.needsHuman)
            }
        }
    }

    /// PNG の印と IHDR だけの、画像として読めないデータ
    static func pngHeader(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let size = withUnsafeBytes(of: width.bigEndian) { Array($0) } + withUnsafeBytes(of: height.bigEndian) { Array($0) }
        let payload = size + [8, 2, 0, 0, 0]
        data.append(contentsOf: withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Array($0) })
        data.append(Data("IHDR".utf8))
        data.append(contentsOf: payload)
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }

    @Test func checksCreativeImages() {
        #expect(CreativeImport.imageProblem(Self.header, kind: .productPageHeader) == nil)
        // RGB でも tRNS（透過にする色）があれば断る
        var transparent = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func chunk(_ type: String, _ payload: [UInt8]) -> Data {
            var data = Data(withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Array($0) })
            data.append(Data(type.utf8))
            data.append(contentsOf: payload)
            data.append(contentsOf: [0, 0, 0, 0])
            return data
        }
        let size = withUnsafeBytes(of: UInt32(3840).bigEndian) { Array($0) } + withUnsafeBytes(of: UInt32(1646).bigEndian) { Array($0) }
        transparent.append(chunk("IHDR", size + [8, 2, 0, 0, 0]))
        transparent.append(chunk("tRNS", [0, 0, 0, 0, 0, 0]))
        transparent.append(chunk("IDAT", [0]))
        #expect(CreativeImport.imageProblem(transparent, kind: .productPageHeader) == "に透過の指定（tRNS）がある")
        #expect(CreativeImport.imageProblem(Self.header, kind: .searchResults)?.contains("寸法") == true)
        #expect(CreativeImport.imageProblem(Data("not png".utf8), kind: .searchResults) == "が PNG でない")
    }
}
