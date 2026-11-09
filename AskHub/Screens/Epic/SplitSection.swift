import SwiftUI

/// 着手前の確認で 1 つの epic に収まらないと分かったときの、理由・分け方の案と、人の判断
struct SplitSection: View {
    let epic: Epic
    let split: SplitProposal

    @Environment(ClientStore.self) private var store
    @State private var isConfirmingSplit = false
    @State private var draft: RequestDraft?

    private var target: IntentTarget {
        .split(epicID: epic.id)
    }

    var body: some View {
        CardSection {
            Text(split.reason)
            ForEach(split.parts, id: \.self) { part in
                VStack(alignment: .leading, spacing: 4) {
                    Text(part.title).rowFont(.title)
                    Text(part.summary).foregroundStyle(.secondary)
                    if split.choice == .split {
                        Button("この案で依頼を書く", systemImage: "square.and.pencil") {
                            draft = RequestDraft(repositoryID: epic.repositoryID, summary: part.title, body: part.summary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if split.choice == nil {
                Group {
                    Button("分けて依頼し直す", systemImage: "square.split.2x1") { isConfirmingSplit = true }
                    Button("このまま 1 つで進める", systemImage: "arrow.right.circle") {
                        Task { await store.send(.decideSplit(epicID: epic.id, choice: .proceed)) }
                    }
                }
                .disabled(store.isReflecting([target]))
            }
            // 選んだ分け方の同期を待つ間の小さな印と、断られた理由
            ReflectionStatusView(target, showsSyncBadge: true)
        } header: {
            Text(split.choice == .split ? "分けて依頼し直す" : "1 つの epic に収まりません")
        } footer: {
            Text(footer)
        }
        .confirmationDialog("この epic をやめて、分けて依頼し直しますか？", isPresented: $isConfirmingSplit, titleVisibility: .visible) {
            Button("分けて依頼し直す", role: .destructive) {
                Task { await store.send(.decideSplit(epicID: epic.id, choice: .split)) }
            }
        } message: {
            Text("この epic はやめます。案ごとに依頼の下書きを出すので、確かめてから送ってください")
        }
        .sheet(item: $draft) { draft in
            NewRequestSheet(draft: draft)
        }
    }

    private var footer: String {
        switch split.choice {
        case nil:
            "このまま進めると、着手前の確認をやり直してゴールを作ります。決めきれない点は、追加の質問か仮の決定としてゴールに書かれます"

        case .split?:
            "この epic はやめました。案ごとに依頼を書いて送ってください"

        case .proceed?:
            "このまま 1 つで進めます"
        }
    }
}
