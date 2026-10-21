@testable import OrchestratorKit
import Testing

// 依頼先のリポジトリの Discussions の設定（Issue #719）

struct IdeaDiscussionSettingsTests {
    @Test func acceptsIdeasOnlyWhenEnabledWithIdeasCategory() {
        #expect(DiscussionSettings(isEnabled: true, categories: ["General", "Ideas"]).ideaProblem == nil)
        // テンプレートから作ったリポジトリは Discussions が無効で、カテゴリも無い
        #expect(DiscussionSettings(isEnabled: false, categories: []).ideaProblem == .disabled)
        #expect(DiscussionSettings(isEnabled: true, categories: ["General", "Q&A"]).ideaProblem == .missingCategory)
    }

    @Test func messageTellsHowToFix() {
        let disabled = IdeaDiscussionProblem.disabled.message(for: "o/r")
        #expect(disabled.hasPrefix("o/r の Discussions が無効で"))
        #expect(disabled.contains("Settings → General → Features で Discussions を有効にしてください"))
        #expect(IdeaDiscussionProblem.missingCategory.message(for: "o/r").contains("カテゴリ「Ideas」を作ってください"))
    }
}
