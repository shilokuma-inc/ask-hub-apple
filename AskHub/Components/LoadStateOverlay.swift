import SwiftUI

/// 読み込み中・読めなかった・空の表示。読めなかったときは「ありません」と出さない
struct LoadStateOverlay<Empty: View>: View {
    let isEmpty: Bool
    let empty: Empty

    @Environment(ClientStore.self) private var store

    var body: some View {
        switch store.phase {
        case .idle, .loading:
            if store.snapshot == nil {
                ProgressView("読み込んでいます")
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("読み込めませんでした", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("もう一度読む") {
                    Task { await store.refresh() }
                }
                .buttonStyle(.glassProminent)
                .keepsControlSize()
            }

        case .loaded:
            if isEmpty {
                empty
            }
        }
    }
}
