import SwiftUI

/// 配信中の版のプロモーションテキストを、言語ごとに直して反映するシート。今の文を入れた状態で開く。
/// 審査に出さずに変えられるので、司令塔が受け付けたらすぐ App Store Connect に書く
struct PromotionalTextSheet: View {
    let release: Release
    let promotionalText: Release.PromotionalText
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var texts: [String: String] = [:]
    @State private var sending = SheetSendState()

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { send() }
                    }
                }
                ForEach(promotionalText.current) { current in
                    Section {
                        TextEditor(text: binding(for: current))
                            .frame(minHeight: 80)
                            .accessibilityIdentifier("promotional-text-\(current.locale)")
                    } header: {
                        Text(current.localeName)
                    } footer: {
                        footer(for: current)
                    }
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("プロモーションテキスト")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("反映する", isSending: sending.isSending) { send() }
                        .disabled(!isReady)
                }
            }
        }
        .sheetSending(sending)
        .sheetSize(.page)
    }

    private func text(of current: Submission.Localized) -> String {
        (texts[current.locale] ?? current.text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func footer(for current: Submission.Localized) -> Text {
        let text = text(of: current)
        let count = "\(text.unicodeScalars.count) / \(Release.PromotionalText.limit) 文字"
        if text.unicodeScalars.count > Release.PromotionalText.limit {
            return Text("\(count)。\(Release.PromotionalText.limit) 文字までにしてください")
        }
        guard text != current.text else { return Text(count) }
        return Text(text.isEmpty ? "\(count)。空にします" : "\(count)。この文に変えます")
    }

    private var isReady: Bool {
        let changed = promotionalText.current.contains { text(of: $0) != $0.text }
        let fits = promotionalText.current.allSatisfy { text(of: $0).unicodeScalars.count <= Release.PromotionalText.limit }
        return changed && fits
    }

    private func binding(for current: Submission.Localized) -> Binding<String> {
        Binding { texts[current.locale] ?? current.text } set: { texts[current.locale] = $0 }
    }

    private func send() {
        let edited = promotionalText.current.map { Submission.Localized(locale: $0.locale, text: texts[$0.locale] ?? $0.text) }
        let intent = HumanIntent.updatePromotionalText(repositoryID: release.repositoryID, version: release.version, texts: edited)
        if sending.submit(intent, in: store) { onClose() }
    }
}
