import SwiftUI

/// 送る前の取り消しの猶予と、送れなかったことを出す帯。どの画面でも下に出す
struct SendStatusBar: View {
    @Environment(ClientStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            if let failure = store.sendFailure {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("送れませんでした: \(failure.message)")
                        .font(.footnote)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("もう一度") {
                        Task { await store.retryFailedSend() }
                    }
                    .font(.footnote.weight(.semibold))
                    Button("閉じる", systemImage: "xmark") { store.dismissSendFailure() }
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                }
                .modifier(BarStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let pending = store.pending {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane")
                        .foregroundStyle(.secondary)
                    Text(pending.message)
                        .font(.footnote)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("取り消す") { store.undo() }
                        .font(.footnote.weight(.semibold))
                }
                .modifier(BarStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(pending.id)
            }
        }
        .padding(.horizontal, 16)
        .animation(.snappy, value: store.pending)
        .animation(.snappy, value: store.sendFailure)
    }

    private struct BarStyle: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: 520)
                .glassEffect(.regular, in: .capsule)
        }
    }
}
