@testable import AskHub
import Foundation
import Testing

/// Siri・ショートカットの登録（言い回し・依頼先の選び方）
@MainActor
struct SiriShortcutsTests {
    /// 設定の案内に出す言い回しは、日本語の Siri に登録した言い回しと同じ
    @Test
    func settingsShowPhrasesRegisteredForJapaneseSiri() throws {
        // ビルドしたアプリの ja.lproj/AppShortcuts.strings（AppShortcuts.xcstrings の ja の訳）
        let url = try #require(
            Bundle.main.url(forResource: "AppShortcuts", withExtension: "strings", subdirectory: nil, localization: "ja")
        )
        let strings = try #require(NSDictionary(contentsOf: url) as? [String: String])
        let registered = strings.values.map { $0.replacingOccurrences(of: "${applicationName}", with: "AskHub") }

        #expect(Set(registered) == Set(SiriShortcutsSection.phrases))
        #expect(registered.count == SiriShortcutsSection.phrases.count)
    }

    /// 依頼先は名前の一部で探せる。声で言った名前のように、大文字小文字・記号・空白が違っても当たる
    @Test(arguments: [
        ("sandbox", true),
        ("AskHub Sandbox", true),
        ("askhub_sandbox", true),
        ("shilokuma", true),
        ("", true),
        ("prime", false)
    ])
    func repositoryMatchesPartOfName(query: String, matches: Bool) {
        #expect(RequestRepositoryQuery.matches("shilokuma-inc/askhub-sandbox", query: query) == matches)
    }

    /// 保存したショートカットの依頼先は、状態リポジトリを読まずに id から戻す（形の違う id は捨てる）
    @Test
    func savedRepositoriesResolveWithoutNetwork() async throws {
        let entities = try await RequestRepositoryQuery().entities(for: ["shilokuma-inc/askhub-sandbox", "not a repo"])

        #expect(entities.map(\.id) == ["shilokuma-inc/askhub-sandbox"])
    }
}
