import SwiftUI

/// 接続の状態の 1 行。取り直しの失敗・一部の取得元の失敗・司令塔の印の古さを、0 件と取り違えないように出す
struct ConnectionStatusView: View {
    /// 司令塔の印がこれより古ければ知らせる
    static let staleHeartbeat: TimeInterval = 15 * 60

    @Environment(ClientStore.self) private var store

    var body: some View {
        let status = Self.status(store: store)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.footnote.weight(.semibold))
                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if status.offersRetry {
                Button("もう一度読む") {
                    Task { await store.refresh() }
                }
                .font(.caption.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    struct Status {
        var title: String
        var detail: String?
        var systemImage: String
        var tint: Color
        var offersRetry = false
    }

    static func status(store: ClientStore) -> Status {
        guard let snapshot = store.snapshot else {
            if case .failed = store.phase {
                return Status(title: "読み込めませんでした", systemImage: "wifi.exclamationmark", tint: Theme.danger, offersRetry: true)
            }
            return Status(title: "読み込んでいます", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
        }
        let checked = "\(RelativeTime.clock(snapshot.fetchedAt)) の内容です"
        if let failure = store.refreshFailure {
            return Status(
                title: "取り直せませんでした",
                detail: "\(failure)。\(checked)",
                systemImage: "wifi.exclamationmark",
                tint: Theme.danger,
                offersRetry: true
            )
        }
        if let failure = snapshot.sourceFailures.first {
            return Status(
                title: "一部を読めませんでした: \(failure.source)",
                detail: "\(failure.message)。ほかは \(checked)",
                systemImage: "exclamationmark.triangle.fill",
                tint: Theme.warning,
                offersRetry: true
            )
        }
        if let commandCenter = snapshot.macs.first(where: { $0.role == .commandCenter }),
           let silent = silence(of: commandCenter, now: store.currentDate()) {
            return Status(
                title: "司令塔（\(commandCenter.name)）から \(silent) 印がありません",
                detail: "質問づくりや通知が止まっている可能性があります",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                tint: Theme.danger
            )
        }
        let online = snapshot.macs.filter(\.isOnline).count
        return Status(
            title: "Mac \(online) / \(snapshot.macs.count) 台がオンライン",
            detail: "\(RelativeTime.clock(snapshot.fetchedAt)) に確かめました",
            systemImage: "checkmark.circle.fill",
            tint: Theme.success
        )
    }

    private static func silence(of mac: Mac, now: Date) -> String? {
        let lastSeen: Date
        switch mac.connection {
        case .online(let date), .offline(let date):
            lastSeen = date
        }
        guard now.timeIntervalSince(lastSeen) >= staleHeartbeat else {
            return nil
        }
        return RelativeTime.duration(since: lastSeen, now: now)
    }
}
