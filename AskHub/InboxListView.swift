import AskHubKit
import SwiftUI

/// 受信箱の一覧の 1 タブ分。要回答と急がないで、行の中身と空のときの文言だけが違う
struct InboxListView<Item: Identifiable, Row: View>: View {
    let title: String
    let items: [Item]
    let emptyTitle: String
    let emptySystemImage: String
    let model: InboxModel
    let url: (Item) -> URL
    @ViewBuilder let row: (Item) -> Row
    let openSettings: () -> Void

    var body: some View {
        List {
            if case let .failed(message) = model.state, !items.isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            ForEach(items) { item in
                // 質問の詳細と回答は後続のタスクで追加する。それまでは GitHub の該当箇所を開く
                Link(destination: url(item)) {
                    row(item)
                        // 行全体をタップできるように幅を広げる
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                // Link の既定のスタイルは行の文字をすべてアクセントカラーにするため、行の配色を使う
                .buttonStyle(.plain)
            }
        }
        .overlay {
            if items.isEmpty {
                emptyState
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("設定", systemImage: "gearshape", action: openSettings)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()

        case .needsToken:
            ContentUnavailableView {
                Label("トークンが未設定です", systemImage: "key")
            } description: {
                Text("設定で GitHub の Personal Access Token を保存してください")
            } actions: {
                Button("設定を開く", action: openSettings)
            }

        case let .failed(message):
            ContentUnavailableView("取得できませんでした", systemImage: "exclamationmark.triangle", description: Text(message))

        case .loaded:
            ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
        }
    }
}
