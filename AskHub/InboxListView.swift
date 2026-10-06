import AskHubKit
import SwiftUI

/// 一覧の見出し付きのまとまり。見出しが無ければ（`header == nil`）見出しなしで並べる
struct InboxListSection<Item: Identifiable>: Identifiable {
    struct Header {
        let title: String
        let systemImage: String
        /// 見出しのアイコンの色。行のラベルと同じ色にして、どのセクションの行か見分けられるようにする
        let tint: Color
    }

    let id: String
    let header: Header?
    let items: [Item]
}

/// 受信箱の一覧の 1 タブ分。要回答と急がないで、行（遷移先を含む）・セクションの分け方・空のときの文言だけが違う
struct InboxListView<Item: Identifiable, Row: View>: View {
    let title: String
    let sections: [InboxListSection<Item>]
    let emptyTitle: String
    let emptySystemImage: String
    let model: InboxModel
    @ViewBuilder let row: (Item) -> Row
    let openSettings: () -> Void

    private var isEmpty: Bool {
        sections.allSatisfy(\.items.isEmpty)
    }

    var body: some View {
        List {
            // 一覧の中身があるときは、空の表示の代わりにここで失敗を知らせる
            if case let .failed(message) = model.state, !isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            ForEach(sections) { section in
                if let header = section.header {
                    Section {
                        rows(of: section)
                    } header: {
                        Label {
                            Text("\(header.title)（\(section.items.count) 件）")
                        } icon: {
                            Image(systemName: header.systemImage)
                                .foregroundStyle(header.tint)
                        }
                    }
                } else {
                    rows(of: section)
                }
            }
        }
        .overlay {
            if isEmpty {
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

    private func rows(of section: InboxListSection<Item>) -> some View {
        ForEach(section.items) { item in
            row(item)
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

extension InboxListView {
    /// セクションに分けずに並べる（「要回答」）
    init(
        title: String,
        items: [Item],
        emptyTitle: String,
        emptySystemImage: String,
        model: InboxModel,
        @ViewBuilder row: @escaping (Item) -> Row,
        openSettings: @escaping () -> Void
    ) {
        self.init(
            title: title,
            sections: [InboxListSection(id: "all", header: nil, items: items)],
            emptyTitle: emptyTitle,
            emptySystemImage: emptySystemImage,
            model: model,
            row: row,
            openSettings: openSettings
        )
    }
}
