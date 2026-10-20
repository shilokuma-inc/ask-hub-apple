import AppIntents

/// Siri・Spotlight・ショートカット App に出す App Shortcuts（Discussion #655）。
/// フレーズは開発言語（en）で書き、日本語の訳は `AppShortcuts.xcstrings` に置く（Siri の言語の訳が無いと、その言語の Siri はフレーズを使えない）
struct AskHubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendIdeaRequestIntent(),
            phrases: [
                "Request with \(.applicationName)",
                "Send a request to \(.applicationName)",
                "Request a feature with \(.applicationName)"
            ],
            shortTitle: "依頼を送る",
            systemImageName: "plus.bubble"
        )
    }
}
