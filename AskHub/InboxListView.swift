import AskHubKit
import SwiftUI

/// 受信箱の一覧の 1 タブ分。要回答と急がないで、行（遷移先を含む）・空のときの文言だけが違う
struct InboxListView<Item: Identifiable, Row: View>: View {
    let title: String
    let items: [Item]
    let emptyTitle: String
    let emptySystemImage: String
    let model: InboxModel
    @ViewBuilder let row: (Item) -> Row
    let openSettings: () -> Void

    var body: some View {
        List {
            // 一覧の中身があるときは、空の表示の代わりにここで失敗を知らせる
            if case let .failed(message) = model.state, !items.isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            ForEach(items) { item in
                row(item)
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
                Text("設定で GitHub の Personal Access Token を保存してください。トークンが無くても、サンプルデータで操作を試せます")
            } actions: {
                Button("設定を開く", action: openSettings)
                TryDemoButton()
            }

        case let .failed(message):
            ContentUnavailableView("取得できませんでした", systemImage: "exclamationmark.triangle", description: Text(message))

        case .loaded:
            ContentUnavailableView(emptyTitle, systemImage: emptySystemImage)
        }
    }
}
