@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 初めての版（配信中の版が無い）の掲載文: 編集できる版の今の文を元に、アプリの中身から一から書く
extension ReleaseWatchTests {
    /// App Store Connect にアプリはあるが、配信中の版が無い。リリースを始めた記録は版の枠を作る
    func startFirstRelease() async throws {
        try await addRepository()
        var file = SubmissionHandlersTests.started()
        file.appStoreVersions = []
        await store.put(StatePath.submission(Self.repo, Self.next), data: try StateFileCoder.encode(file))
        hosting.state.withLock { $0.branches["develop"] = Self.developHead }
        sources.state.withLock { state in
            state.snapshot.files = [.init(path: "Configs/Project.xcconfig", content: "MARKETING_VERSION = 1.2.0\n")]
        }
        appStore.state.withLock { state in
            state.apps = [AppStoreApp(id: "6740000001", bundleId: "jp.shilokuma.OshiCon", name: "推し活カウントダウン")]
            // 版の枠（createVersion が作る id）の言語。新しいアプリなので掲載文は空
            state.localizations["v-1-2-0"] = [
                AppStoreLocalization(id: "l-ja", locale: "ja", whatsNew: nil, listing: .init(locale: "ja"))
            ]
        }
    }

    @Test func draftsWholeListingForFirstVersion() async throws {
        try await startFirstRelease()
        listingDrafter.proposal.withLock {
            $0 = ListingProposal(
                drafts: [ListingText(locale: "ja", description: "推しの予定までの日数を数えるアプリです。", keywords: "推し活,カウントダウン")],
                reason: "README と画面の文言から書きました"
            )
        }
        await watch().refresh()
        let file = try await submission()
        let material = try #require(listingDrafter.materials.withLock { $0.first })
        #expect(material.firstVersion)
        #expect(material.current == [ListingText(locale: "ja")])
        let listing = try #require(file.listing)
        #expect(listing.current == [ListingText(locale: "ja")])
        #expect(listing.drafts.first?.description == "推しの予定までの日数を数えるアプリです。")
        // 初めての版は What's New を持たない
        #expect(file.whatsNew?.drafts.isEmpty == true)
    }

    @Test func requiresDescriptionAndKeywordsForEveryLocaleOfFirstVersion() {
        let current = [ListingText(locale: "ja"), ListingText(locale: "en-US", description: "Counts days.", keywords: "oshi")]
        // 英語は今の文があるので書かなくてよい。日本語はキーワードが無い
        let partial = ListingProposal(drafts: [ListingText(locale: "ja", description: "日数を数えます。")], reason: "書きました")
        let problems = ListingRules.problems(partial, current: current, firstVersion: true)
        #expect(problems == ["初めての版の ja に keywords が無い（一から書く）"])
        // 2 つ目以降の版では、変えない欄があってよい
        #expect(ListingRules.problems(partial, current: current).isEmpty)
        let material = ListingMaterial(
            repo: Self.repo,
            appName: "推し活カウントダウン",
            version: Self.next,
            commit: Self.developHead,
            changes: ReleaseChanges(previousTag: nil, changes: []),
            epics: [],
            current: current,
            firstVersion: true
        )
        #expect(ClaudeListingDrafter.firstVersionPrompt(material).contains("初めての版 1.2.0"))
    }
}
