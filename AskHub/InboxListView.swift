import AskHubKit
import SwiftUI

/// 「任意判断」「実機確認」の一覧の 1 タブ分。タブごとに、行（遷移先を含む）と空のときの文言だけが違う。
///
/// ツールバーのメニューで、リポジトリでの絞り込みと作成日・更新日での並び替えを選べる（Discussion #586）。
/// 選んだ値はタブごとの `@State` に持ち、保存しない（再起動後は「すべて」「更新日（新しい順）」に戻る）
struct InboxListView<Row: View>: View {
    let title: String
    /// このタブの全件（絞り込む前）
    let items: [InboxIssue]
    let emptyTitle: String
    /// 絞り込んだ結果が空のときの文言
    let filteredEmptyTitle: String
    let emptySystemImage: String
    let model: InboxModel
    @ViewBuilder let row: (InboxIssue) -> Row
    let openSettings: () -> Void

    @State private var repositoryFilter = InboxRepositoryFilter.all
    @State private var sortOrder = InboxIssueSortOrder.default

    private var repositoryOptions: [InboxRepositoryOption] {
        InboxRepositoryOption.options(in: items)
    }

    var body: some View {
        let shownItems = items.arranged(filter: repositoryFilter, order: sortOrder)
        List {
            // 一覧の中身があるときは、空の表示の代わりにここで失敗を知らせる
            if case let .failed(message) = model.state, !items.isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            ForEach(shownItems) { item in
                row(item)
            }
        }
        .overlay {
            if items.isEmpty {
                emptyState
            } else if shownItems.isEmpty {
                filteredEmptyState
            }
        }
        // 絞り込み中のリポジトリが一覧から消えたら（すべて閉じた・取り直したら無くなったなど）「すべて」に戻す
        .onChange(of: repositoryOptions) {
            repositoryFilter = repositoryFilter.resolved(in: items)
        }
        .refreshable { await model.refresh() }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                filterMenu
            }
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

    /// 絞り込みと並び替えのメニュー。絞り込み中はアイコンを塗りにする
    private var filterMenu: some View {
        Menu {
            Section("リポジトリ") {
                Picker("リポジトリ", selection: $repositoryFilter) {
                    Text("すべて（\(items.count)）").tag(InboxRepositoryFilter.all)
                    ForEach(repositoryOptions) { option in
                        Text("\(option.displayName)（\(option.count)）")
                            .tag(InboxRepositoryFilter.repository(option.repository))
                    }
                }
                .pickerStyle(.inline)
            }
            Section("並び替え") {
                Picker("並び替え", selection: $sortOrder) {
                    ForEach(InboxIssueSortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label(
                "絞り込みと並び替え",
                systemImage: repositoryFilter == .all
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .disabled(items.isEmpty)
    }

    /// 絞り込んだ結果が空のとき。「すべて」に戻せるようにする
    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(filteredEmptyTitle, systemImage: emptySystemImage)
        } actions: {
            Button("すべてを表示") {
                repositoryFilter = .all
            }
        }
    }
}
