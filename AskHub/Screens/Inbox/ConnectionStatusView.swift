import SwiftUI

/// 接続の状態の 1 行。取り直しの失敗（GitHub の上限なら戻る時刻）・一部の取得元の失敗・司令塔の印の古さを、0 件と取り違えないように出す。
/// GitHub の REST の上限の残りは、ふだんは小さく添え、少なくなったら警告にする
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
                    .appFont(.footnote, weight: .semibold)
                if let detail = status.detail {
                    Text(detail)
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if status.offersRetry {
                Button("もう一度読む") {
                    Task { await store.refresh() }
                }
                .appFont(.caption, weight: .semibold)
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
        let paused = store.isRefreshPaused ? store.refreshPausedUntil : nil
        guard let snapshot = store.snapshot else {
            if let paused {
                return rateLimited(until: paused, detail: nil)
            }
            if case .failed = store.phase {
                return Status(title: "読み込めませんでした", systemImage: "wifi.exclamationmark", tint: Theme.danger, offersRetry: true)
            }
            return Status(title: "読み込んでいます", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
        }
        let checked = "\(RelativeTime.clock(snapshot.fetchedAt)) の内容です"
        if let paused {
            return rateLimited(until: paused, detail: checked)
        }
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
        return healthy(snapshot, now: store.currentDate())
    }

    /// 読めていて、司令塔も動いているとき。GitHub の REST の残りを小さく添え、少なくなったら警告にする
    private static func healthy(_ snapshot: ClientSnapshot, now: Date) -> Status {
        let quota = snapshot.githubQuota(now: now)
        if let quota, quota.isLow(now: now) {
            return Status(
                title: "GitHub の残りが少なくなっています（\(GitHubQuota.count(quota.remaining)) 回）",
                detail: "\(RelativeTime.clock(quota.resetAt)) に戻ります。GitHub を多く使うものを止めてください",
                systemImage: "gauge.with.dots.needle.0percent",
                tint: Theme.warning
            )
        }
        let online = snapshot.macs.filter(\.isOnline).count
        let remaining = quota.map { " · GitHub の残り \(GitHubQuota.count($0.remaining)) 回" } ?? ""
        return Status(
            title: "Mac \(online) / \(snapshot.macs.count) 台がオンライン",
            detail: "\(RelativeTime.clock(snapshot.fetchedAt)) に確かめました\(remaining)",
            systemImage: "checkmark.circle.fill",
            tint: Theme.success
        )
    }

    /// GitHub の上限に当たり、戻る時刻まで取り直しを休んでいる（読み直しても弾かれるので、もう一度読むボタンは出さない）
    private static func rateLimited(until: Date, detail: String?) -> Status {
        Status(
            title: "GitHub の上限に当たりました",
            detail: ["\(RelativeTime.clock(until)) に戻ります", detail].compactMap(\.self).joined(separator: "。"),
            systemImage: "hourglass",
            tint: Theme.warning
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
