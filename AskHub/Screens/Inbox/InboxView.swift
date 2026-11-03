import SwiftUI

/// 「あなたの番」。人の出番を、種類をまたいで 1 つの一覧にする
struct InboxView: View {
    let selection: Binding<AppRoute?>?

    @Environment(ClientStore.self) private var store

    var body: some View {
        let items = store.inboxItems
        let blocking = items.filter { $0.urgency == .blocking }
        let whenFree = items.filter { $0.urgency == .whenFree }
        let deckCount = store.deckCards(.all).count
        RouteList(selection: selection) {
            // Mac・iPad（選択で詳細を出す 3 列）では、接続の状態はサイドバーの下に出す
            if selection == nil {
                Section {
                    ConnectionStatusView()
                }
            }
            if deckCount > 0 {
                Section {
                    NavigationLink(value: AppRoute.deck(.all)) {
                        DeckShortcutRow(count: deckCount)
                    }
                }
            }
            if !blocking.isEmpty {
                Section("進行が止まっています · \(blocking.count)") {
                    ForEach(blocking) { item in
                        NavigationLink(value: item.route) { InboxRow(item: item) }
                    }
                }
            }
            if !whenFree.isEmpty {
                Section("時間のあるときに · \(whenFree.count)") {
                    ForEach(whenFree) { item in
                        NavigationLink(value: item.route) { InboxRow(item: item) }
                    }
                }
            }
        }
        .overlay { LoadStateOverlay(isEmpty: items.isEmpty, empty: InboxEmptyView()) }
        .pastelBackground()
        .navigationTitle("あなたの番")
        .toolbar { SectionToolbar() }
        .refreshable { await store.refresh() }
    }
}

/// 一覧の 1 行。アプリのアイコンに種類の印を重ね、どのアプリの何の出番かを一目で分かるようにする
struct InboxRow: View {
    let item: InboxItem

    @Environment(ClientStore.self) private var store
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if let repository = store.repository(item.repositoryID) {
                    AppIconView(repository: repository, size: 40)
                } else {
                    MacIconView(size: 40)
                }
                InboxKindBadge(kind: item.kind)
                    .offset(x: 5, y: 5)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(RelativeTime.string(item.since, now: store.currentDate()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(item.context)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(item.detail)
                    .font(.footnote)
                    .foregroundStyle(detailStyle)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// 失敗は赤で出す。Mac の一覧で選んだ行（濃い背景）では、色を付けずに読みやすくする
    private var detailStyle: AnyShapeStyle {
        item.kind == .blocker && backgroundProminence != .increased ? AnyShapeStyle(Theme.danger) : AnyShapeStyle(.secondary)
    }
}

/// 「まとめて判断する」の入口。次に流れてくるカードのアプリのアイコンを重ねて出す
private struct DeckShortcutRow: View {
    let count: Int

    @Environment(ClientStore.self) private var store

    var body: some View {
        let repositories = store.deckCards(.all).compactMap { store.repository($0.repositoryID) }
        let unique = repositories.reduce(into: [TargetRepository]()) { result, repository in
            if !result.contains(repository) {
                result.append(repository)
            }
        }
        HStack(spacing: 12) {
            HStack(spacing: -10) {
                ForEach(unique.prefix(4)) { repository in
                    AppIconView(repository: repository, size: 30)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.background, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("まとめて判断する")
                    .font(.headline)
                Text("\(count) 件をスワイプで答える")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }
}

/// 人の出番が無いとき。機械が何件を進めているかと、いつ確かめたかを出す
private struct InboxEmptyView: View {
    @Environment(ClientStore.self) private var store

    var body: some View {
        let working = store.snapshot?.activeEpics.filter { !$0.activities.isEmpty }.count ?? 0
        ContentUnavailableView {
            Label("あなたの番はありません", systemImage: "checkmark.circle")
        } description: {
            if let fetchedAt = store.snapshot?.fetchedAt {
                Text("Claude が \(working) 件を進めています。\(RelativeTime.clock(fetchedAt)) に確かめました")
            }
        }
    }
}

/// Mac の項目のアイコン
struct MacIconView: View {
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary, in: .rect(cornerRadius: size * 0.225, style: .continuous))
            .accessibilityHidden(true)
    }
}
