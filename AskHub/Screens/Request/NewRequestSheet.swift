import SwiftUI

/// 新しい依頼。依頼先には対象のリポジトリだけを出す
struct NewRequestSheet: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryID: TargetRepository.ID?
    @State private var summary = ""
    @State private var requestBody = ""

    var body: some View {
        let repositories = store.snapshot?.repositories ?? []
        NavigationStack {
            Form {
                Section("依頼先") {
                    Picker("アプリ", selection: $repositoryID) {
                        Text("選んでください").tag(TargetRepository.ID?.none)
                        ForEach(repositories) { repository in
                            Text(repository.appName).tag(Optional(repository.id))
                        }
                    }
                    if let repository = store.repository(repositoryID) {
                        AppHeaderView(repository: repository, subtitle: repository.fullName)
                    }
                }
                Section("作りたいもの") {
                    TextField("要約（例: 週ごとのまとめ通知）", text: $summary)
                    TextField("依頼の内容", text: $requestBody, axis: .vertical)
                        .lineLimit(4...12)
                }
                Section {
                    Label("添付は、つなぎ込みのときに今の部品を使って足します", systemImage: "paperclip")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("新しい依頼")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("送る") {
                        guard let repositoryID else {
                            return
                        }
                        Task {
                            await store.send(.request(repositoryID: repositoryID, summary: summary, body: requestBody))
                            dismiss()
                        }
                    }
                    .disabled(repositoryID == nil || summary.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
