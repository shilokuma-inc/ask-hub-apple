import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 「手動で回す」で投稿した後に出す、Claude Code に渡す指示。コピーして、担当者の Mac の Claude Code に貼る
struct ManualLoopInstructionSection: View {
    let instruction: String
    /// 担当者が自分でなければ、その login（担当者に通知したことを伝える）
    var assignee: String?
    let close: () -> Void

    var body: some View {
        Section {
            Text(instruction)
                .textSelection(.enabled)
                .accessibilityIdentifier("manual-loop-instruction")
            CopyTextButton(text: instruction, title: "指示をコピー")
                .accessibilityIdentifier("copy-manual-loop-instruction")
            Button("閉じる", action: close)
        } header: {
            Text("手動ループ")
        } footer: {
            if let assignee {
                Text("manual-loop を付け、@\(assignee) さんに担当を知らせました（GitHub の通知が届きます）。"
                    + "この指示は、担当者のステータスタブの「手動ループ」にも出ます")
            } else {
                Text("manual-loop を付けました。このリポジトリの checkout で開いた Claude Code に、この指示を貼ってください。"
                    + "Claude が scripts/askhub-manual.sh で準備し、ループの状態を書きながら回し、最終 PR を作ります")
            }
        }
    }
}

/// 文字列をクリップボードにコピーするボタン。押すと「コピーしました」に変わる
struct CopyTextButton: View {
    let text: String
    let title: String
    @State private var isCopied = false

    var body: some View {
        Button(isCopied ? "コピーしました" : title, systemImage: isCopied ? "checkmark" : "doc.on.doc") {
            Self.copy(text)
            isCopied = true
        }
    }

    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
