import AppIntents

/// Siri・Spotlight・ショートカットのアプリに出す App Shortcuts（Issue #1122）。
///
/// フレーズは開発言語（en）で書き、日本語の訳は `AppShortcuts.xcstrings` に置く（Siri の言語の訳が無いと、その言語の Siri はフレーズを使えない）。
/// 日本語の言い回しは、設定の案内（`SiriShortcutsSection.phrases`）と同じにする
struct AskHubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendRequestIntent(),
            phrases: [
                "Request with \(.applicationName)",
                "Send a request to \(.applicationName)",
                "New request with \(.applicationName)"
            ],
            shortTitle: "依頼を送る",
            systemImageName: "plus.bubble"
        )
    }
}
