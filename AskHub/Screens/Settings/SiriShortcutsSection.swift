import SwiftUI

/// 設定の「Siri とショートカット」。話しかける言い回しと、聞かれること・送るときの決まりを文で出す（Issue #1122）。
///
/// `SiriTipView` は macOS に無く、`ShortcutsLink` は iOS にしか無いので使わない（iOS と macOS で同じ View にする）
struct SiriShortcutsSection: View {
    /// 日本語の Siri の言い回し。`AppShortcuts.xcstrings` の `ja` の訳と同じ（`SiriShortcutsSectionTests` で確かめる）
    static let phrases = [
        "AskHubで依頼",
        "AskHubに依頼を送る",
        "AskHubで新しい依頼"
    ]

    var body: some View {
        Section {
            ForEach(Self.phrases, id: \.self) { phrase in
                Label("「\(phrase)」", systemImage: "waveform")
            }
        } header: {
            Text("Siri とショートカット")
        } footer: {
            Text("""
            依頼先（対象のリポジトリ）と依頼の文を聞かれ、確かめずに送ります。1 行目が要約、2 行目からが依頼の内容になります。\
            ロック中は解除してから送ります。この端末の鍵を登録するまでは送れません。\
            ショートカットのアプリの「依頼を送る」で、依頼先を決めたショートカットも作れます
            """)
        }
    }
}
