import SwiftUI

/// リポジトリの画面の一番上の「やること」。押すと、操作のある画面・シート・同じ画面の節へ移る。何も無ければ出さない
struct RepositoryTodoSection: View {
    let items: [RepositoryTodo]
    /// 画面を開かない行き先（シートを開く・同じ画面の節へ送る）
    let perform: (RepositoryTodo.Action) -> Void

    var body: some View {
        if !items.isEmpty {
            CardSection("やること · \(items.count)") {
                ForEach(items) { item in
                    if case let .route(route) = item.action {
                        NavigationLink(value: route) { RepositoryTodoRow(item: item) }
                    } else {
                        Button { perform(item.action) } label: { RepositoryTodoRow(item: item) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// やることの 1 行（印・何をするか・詳しく）。アプリはこの画面で分かるので、あなたの番の行と違ってアイコンとアプリ名を出さない
private struct RepositoryTodoRow: View {
    let item: RepositoryTodo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            InboxKindBadge(kind: item.kind, systemImage: systemImage, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).rowFont(.title).lineLimit(2)
                    ReflectionBadge(item.targets)
                }
                Text(item.detail)
                    .rowFont(.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .compactRow()
        .accessibilityElement(children: .combine)
    }

    /// シートを開く行は、開くものの印にする（あなたの番の印は保護の盾）
    private var systemImage: String? {
        switch item.action {
        case .buildSettings: "slider.horizontal.3"
        case .protection, .setup, .route: nil
        }
    }
}
