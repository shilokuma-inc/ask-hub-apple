import AskHubKit
import SwiftUI

/// 受信箱の一覧の 1 タブ分。要回答と急がないで、行（遷移先を含む）・空のときの文言・先頭の節だけが違う
struct InboxListView<Item: Identifiable, Row: View, Leading: View>: View {
    let title: String
    let items: [Item]
    let emptyTitle: String
    let emptySystemImage: String
    let model: InboxModel
    @ViewBuilder let row: (Item) -> Row
    let openSettings: () -> Void
    /// 一覧の先頭に置く節（急がないの「ループの開始待ち」）
    var leadingIsEmpty = true
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        List {
            // 一覧の中身（items または先頭の節）があるときは、空の表示の代わりにここで失敗を知らせる
            if case let .failed(message) = model.state, !(items.isEmpty && leadingIsEmpty) {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            leading()
            ForEach(items) { item in
                row(item)
            }
        }
        .overlay {
            if items.isEmpty && leadingIsEmpty {
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

extension InboxListView where Leading == EmptyView {
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
            items: items,
            emptyTitle: emptyTitle,
            emptySystemImage: emptySystemImage,
            model: model,
            row: row,
            openSettings: openSettings,
            leading: { EmptyView() }
        )
    }
}

/// 「ループの開始待ち」の節。担当 PC のいないリポジトリは「担当 PC なし」と出す
struct WaitingDiscussionsSection: View {
    let waiting: [WaitingDiscussion]

    var body: some View {
        if !waiting.isEmpty {
            Section {
                ForEach(waiting) { discussion in
                    Link(destination: discussion.subject.url) {
                        WaitingDiscussionRow(discussion: discussion)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("ループの開始待ち")
            } footer: {
                Text("担当 PC のオーケストレーターが 30 分以上確認していないリポジトリは「担当 PC なし」と出します")
            }
        }
    }
}

struct WaitingDiscussionRow: View {
    let discussion: WaitingDiscussion

    var body: some View {
        // 相対時刻を出さないので、表示のたびの時刻で判定すればよい
        let isAssigned = discussion.isAssigned(now: Date())
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(discussion.subject.shortReference)
                    .foregroundStyle(.secondary)
                Spacer()
                if isAssigned {
                    Label("担当 PC が起動します", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                } else {
                    Label("担当 PC なし", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)

            Text(discussion.subject.title)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
