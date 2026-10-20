@testable import AskHub
import Foundation
import Testing

@MainActor
struct SiriShortcutsHelpTests {
    @Test func helpShowsPhrasesRegisteredForJapaneseSiri() throws {
        // ビルドしたアプリの ja.lproj/AppShortcuts.strings（AppShortcuts.xcstrings の ja の訳）
        let url = try #require(
            Bundle.main.url(forResource: "AppShortcuts", withExtension: "strings", subdirectory: nil, localization: "ja")
        )
        let strings = try #require(NSDictionary(contentsOf: url) as? [String: String])
        let registered = strings.values.map { $0.replacingOccurrences(of: "${applicationName}", with: "AskHub") }

        #expect(Set(registered) == Set(SiriShortcutsHelpView.phrases))
        #expect(registered.count == SiriShortcutsHelpView.phrases.count)
    }
}
