import SwiftUI

/// 送る前に文を書いてもらうシート（説明を求める・直してほしい・問題あり など）
struct TextRequestSheet: View {
    let request: TextRequest
    /// 何について書いているか。入力欄の上に出す（まとめて判断するの札）
    var subject: Subject?
    /// 開いてすぐ入力欄にフォーカスを当てるか。当てないときは、入力欄を押してから書く（iOS ではそのときにキーボードが出る）
    var focusesOnAppear = true
    let onSend: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let subject {
                    Section {
                        SubjectRow(subject: subject)
                    }
                }
                Section {
                    // Mac の Form では名前が入力欄の左に並んで欄が狭くなるので、名前は隠して入力欄の中に出す
                    TextField(request.prompt, text: $text, prompt: Text(request.prompt), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(4...10)
                        .focused($isFocused)
                        .accessibilityIdentifier("textRequest.field")
                } footer: {
                    if request.allowsEmpty {
                        Text("空のままでも送れます")
                    }
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle(request.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送る") { onSend(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .disabled(!request.allowsEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            // 開いてすぐフォーカスを当てることがあるので、「完了」はフォーカスが付いてから足す
            .keyboardDoneButton($isFocused, onlyWhileFocused: true)
            .onAppear {
                if focusesOnAppear {
                    isFocused = true
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheetSize(.form)
    }
}

extension TextRequestSheet {
    /// 何について書いているか（どのアプリのどの判断か・札の題）
    struct Subject: Equatable {
        /// 例: 習慣ログ · 実機で確かめる · TestFlight 1.4.0 (52)
        var context: String
        var title: String
    }
}

extension TextRequestSheet.Subject {
    /// 判断の札から作る。アプリの名前が分からなければ、札の種類だけを出す
    init(card: DeckCard, appName: String?) {
        self.init(context: [appName, card.kindLabel].compactMap(\.self).joined(separator: " · "), title: card.title)
    }
}

/// 入力欄の上に出す、何について書いているかの行
private struct SubjectRow: View {
    let subject: TextRequestSheet.Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(subject.context)
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Text(subject.title)
                .appFont(.headline, weight: .semibold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("textRequest.subject")
    }
}

extension TextRequest: Identifiable {
    var id: Self { self }
}
