import SwiftUI

/// 終わったもの（マージした・やめた epic）をすべて、新しい順に並べる。進行中には新しいものだけを出すので、それより前のものはここから見返す
struct FinishedEpicListView: View {
    @Environment(ClientStore.self) private var store

    var body: some View {
        let finished = (store.snapshot?.epics ?? []).filter { !$0.isActive }.sorted { $0.updatedAt > $1.updatedAt }
        List {
            if !finished.isEmpty {
                // Mac・iPad の詳細の列には画面の名前が出ないので、見出しにも名前を入れる（進行中の見出しと同じ形）
                CardSection("終わったもの · \(finished.count)") {
                    ForEach(finished) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                }
            }
        }
        .overlay {
            if finished.isEmpty {
                ContentUnavailableView("終わったものはありません", systemImage: "checkmark.seal")
            }
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("終わったもの")
    }
}
