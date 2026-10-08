import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 「手動で回す」で投稿した後に出す、Claude Code に渡す指示。コピーして、手元の Mac の Claude Code に貼る
struct ManualLoopInstructionSection: View {
    let instruction: String
    let close: () -> Void
    @State private var isCopied = false

    var body: some View {
        Section {
            Text(instruction)
                .textSelection(.enabled)
                .accessibilityIdentifier("manual-loop-instruction")
            Button(isCopied ? "コピーしました" : "指示をコピー", systemImage: isCopied ? "checkmark" : "doc.on.doc") {
                Self.copy(instruction)
                isCopied = true
            }
            .accessibilityIdentifier("copy-manual-loop-instruction")
            Button("閉じる", action: close)
        } header: {
            Text("手で回す")
        } footer: {
            Text("manual-loop を付けました。このリポジトリの checkout で開いた Claude Code に、この指示を貼ってください。"
                + "Claude が ready-for-loop を外し、ループの状態（loop-status）を書きながらループを回し、最終 PR を作ります")
        }
    }

    private static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
