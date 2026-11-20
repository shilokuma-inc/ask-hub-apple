@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// 掲載文の案をそろえる・確かめる（`ListingRules`）と、Claude に頼む形（`ClaudeListingDrafter`）
struct ListingDraftTests {
    let current = [
        ListingText(locale: "ja", description: "推しの予定を数えるアプリ。お問い合わせ: https://example.com/support", keywords: "推し活,カウントダウン"),
        ListingText(locale: "en-US", description: "Count down to your oshi events", promotionalText: "New!")
    ]

    @Test func normalizeDropsUnchangedFieldsAndLocales() {
        let proposal = ListingProposal(
            drafts: [
                ListingText(locale: "ja", description: "推しの予定を数えるアプリ。お問い合わせ: https://example.com/support", keywords: " 推し活,カウントダウン,ウィジェット "),
                ListingText(locale: "en-US", promotionalText: "New!")
            ],
            reason: "  ウィジェットを足したので、キーワードに入れる案です\n"
        )
        let normalized = ListingRules.normalize(proposal, current: current)
        #expect(normalized.drafts == [ListingText(locale: "ja", keywords: "推し活,カウントダウン,ウィジェット")])
        #expect(normalized.reason == "ウィジェットを足したので、キーワードに入れる案です")
    }

    @Test func allowsWhatTheCurrentTextAlreadyHas() {
        // 今の説明文にある URL は残してよい
        let kept = ListingProposal(
            drafts: [ListingText(locale: "ja", description: "推しの予定を数え、ウィジェットにも出せるアプリ。お問い合わせ: https://example.com/support")],
            reason: "ウィジェットを足した"
        )
        #expect(ListingRules.problems(kept, current: current).isEmpty)
        // 今の文に無い URL・開発の道具の名前は足さない
        let added = ListingProposal(
            drafts: [ListingText(locale: "en-US", description: "Built with AskHub. See https://example.com")],
            reason: "説明を足した"
        )
        let problems = ListingRules.problems(added, current: current)
        #expect(problems.contains { $0.contains("URL") } && problems.contains { $0.contains("開発の道具") })
        // 今の文に URL があっても、別の URL を足したら断る
        let another = ListingProposal(
            drafts: [ListingText(locale: "ja", description: "推しの予定を数えるアプリ。お問い合わせ: https://example.com/support https://example.org")],
            reason: "説明を足した"
        )
        #expect(ListingRules.problems(another, current: current).contains { $0.contains("https://example.org") })
    }

    @Test func refusesUnknownLocalesLongKeywordsAndEmptyItems() {
        let proposal = ListingProposal(
            drafts: [
                ListingText(locale: "fr", keywords: "oshi"),
                ListingText(locale: "ja", keywords: String(repeating: "推し活,", count: 9) + "カウントダウン"),
                ListingText(locale: "en-US", keywords: "oshi,,countdown")
            ],
            reason: ""
        )
        let problems = ListingRules.problems(proposal, current: current)
        #expect(problems.contains { $0.contains("今の掲載文に無い言語（fr）") })
        #expect(problems.contains { $0.contains("100 バイト") })
        #expect(problems.contains { $0.contains("空の語") })
        #expect(problems.contains { $0.contains("reason") })
    }

    @Test func promptAndSchemaCarryCurrentListing() throws {
        let material = ListingMaterial(
            repo: RepositoryFullName(rawValue: "shariverse/oshikatsu-countdown-ios")!,
            appName: "推し活カウントダウン",
            version: MarketingVersion(rawValue: "1.2.0")!,
            commit: String(repeating: "b", count: 40),
            changes: ReleaseChanges(
                previousTag: "v1.1.0",
                changes: [.init(commit: String(repeating: "f", count: 40), pullRequest: 12, title: "ウィジェットを足す")]
            ),
            epics: [],
            current: current
        )
        let prompt = ClaudeListingDrafter.prompt(material)
        #expect(prompt.contains("\"keywords\" : \"推し活,カウントダウン\""))
        #expect(prompt.contains("#12 ウィジェットを足す") && prompt.contains("v1.1.0（前に配信した版）"))
        let schema = ClaudeListingDrafter.schema(locales: ["ja", "en-US"])
        guard case let .object(root) = schema, case let .object(properties)? = root["properties"],
              case let .object(drafts)? = properties["drafts"], case let .object(items)? = drafts["items"],
              case let .object(fields)? = items["properties"], case let .object(locale)? = fields["locale"] else {
            Issue.record("スキーマの形が違う")
            return
        }
        #expect(locale["enum"] == .array([.string("ja"), .string("en-US")]))
        #expect(Set(fields.keys) == ["locale", "description", "keywords", "promotionalText"])
    }
}
