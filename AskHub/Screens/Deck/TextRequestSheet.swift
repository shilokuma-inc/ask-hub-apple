import SwiftUI

/// 送る前に文を書いてもらうシート（説明を求める・直してほしい・問題あり など）
struct TextRequestSheet: View {
    let request: TextRequest
    let onSend: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(request.prompt, text: $text, axis: .vertical)
                        .lineLimit(4...10)
                        .focused($isFocused)
                } footer: {
                    if request.allowsEmpty {
                        Text("空のままでも送れます")
                    }
                }
            }
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
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

extension TextRequest: Identifiable {
    var id: Self { self }
}
