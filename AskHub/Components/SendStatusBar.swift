import SwiftUI

/// 送る前の取り消しの猶予と、送れたこと・送れなかったことを出す帯。どの画面でも下に出す
struct SendStatusBar: View {
    @Environment(ClientStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            if let notice = store.notice {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.message)
                            .appFont(.footnote, weight: .semibold)
                            .lineLimit(2)
                        Text(notice.detail)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button("閉じる", systemImage: "xmark") { store.dismissNotice() }
                        .labelStyle(.iconOnly)
                        .appFont(.footnote)
                }
                .modifier(BarStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(notice.id)
            }
            if let rejection = store.rejections.first {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rejection.message)
                            .appFont(.footnote, weight: .semibold)
                            .lineLimit(2)
                        Text(rejection.detail)
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                        if store.rejections.count > 1 {
                            Text("ほかに \(store.rejections.count - 1) 件（閉じると次を出します）")
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("閉じる", systemImage: "xmark") { store.dismissRejection() }
                        .labelStyle(.iconOnly)
                        .appFont(.footnote)
                }
                .modifier(BarStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(rejection.id)
            }
            if let failure = store.sendFailure {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text("送れませんでした: \(failure.message)")
                        .appFont(.footnote)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("もう一度") {
                        Task { await store.retryFailedSend() }
                    }
                    .appFont(.footnote, weight: .semibold)
                    Button("閉じる", systemImage: "xmark") { store.dismissSendFailure() }
                        .labelStyle(.iconOnly)
                        .appFont(.footnote)
                }
                .modifier(BarStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let pending = store.pending {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane")
                        .foregroundStyle(.secondary)
                    Text(pending.message)
                        .appFont(.footnote)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("取り消す") { store.undo() }
                        .appFont(.footnote, weight: .semibold)
                }
                .modifier(BarStyle())
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(pending.id)
            }
        }
        .padding(.horizontal, 16)
        .keepsControlSize()
        .animation(.snappy, value: store.pending)
        .animation(.snappy, value: store.sendFailure)
        .animation(.snappy, value: store.notice)
        .animation(.snappy, value: store.rejections)
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
