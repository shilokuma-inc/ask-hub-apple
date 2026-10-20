import SwiftUI

/// Siri・ショートカットからの依頼の使い方（Discussion #655 の Q1 の補足）。設定と「新しい依頼」の「機能追加・修正」から開く
struct SiriShortcutsHelpView: View {
    var body: some View {
        Form {
            Section {
                ForEach(Self.phrases, id: \.self) { phrase in
                    Label("「\(phrase)」", systemImage: "waveform")
                }
            } header: {
                Text("話しかけるフレーズ")
            } footer: {
                Text("iPhone・iPad・Mac の Siri に話しかけます。Spotlight やショートカット App では「依頼を送る」から始められます。")
            }

            Section {
                Label("依頼先のリポジトリ（候補から選ぶ）", systemImage: "1.circle")
                Label("要約（1 行。Issue のタイトルになります）", systemImage: "2.circle")
                Label("依頼文", systemImage: "3.circle")
            } header: {
                Text("聞かれる順番")
            } footer: {
                Text("依頼先の候補は「新しい依頼」と同じく、設定の organization のリポジトリです。名前の一部を言っても探せます。")
            }

            Section("送るときの注意") {
                Text("送る前の確認はありません。依頼文まで答えると、そのまま Issue を作ります。")
                Text("iPhone・iPad がロックされているときは、Face ID・Touch ID・パスコードで解除してから送ります。")
                Text("送れるのは「機能追加・修正」の依頼だけです。「新しいアプリ」「リリース準備」はアプリから送ってください。")
                Text("Siri から送った依頼は、「新しい依頼」の「送った依頼」には出ません。GitHub の Issue に残ります。")
                Text("アプリの設定に保存したトークンで送ります。デモモードの間は GitHub に送りません。")
            }

            Section {
                Text("ショートカット App で AskHub の「機能追加・修正を依頼」のアクションを追加し、依頼先を選んでおくと、いつも同じリポジトリに依頼する自分用のショートカットを作れます。")
            } header: {
                Text("依頼先を固定する")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Siri とショートカット")
    }

    /// 日本語の Siri のフレーズ。`AppShortcuts.xcstrings` の `ja` の訳と同じ（`SiriShortcutsHelpTests` で確かめる）
    static let phrases = [
        "AskHubで依頼",
        "AskHubに依頼を送る",
        "AskHubで機能追加を依頼"
    ]
}

/// 「新しい依頼」の「機能追加・修正」と設定から、使い方の画面を開く行
struct SiriShortcutsHelpLink: View {
    let title: String

    var body: some View {
        NavigationLink {
            SiriShortcutsHelpView()
        } label: {
            Label(title, systemImage: "mic")
        }
    }
}

#Preview {
    NavigationStack {
        SiriShortcutsHelpView()
    }
}
