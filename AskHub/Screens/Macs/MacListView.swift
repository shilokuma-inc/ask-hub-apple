import SwiftUI

/// 「Mac」。Mac ごとの生きている印・空き容量・負荷・持っているジョブを出す
struct MacListView: View {
    let selection: Binding<AppRoute?>?

    @Environment(ClientStore.self) private var store

    var body: some View {
        let macs = store.snapshot?.macs ?? []
        RouteList(selection: selection) {
            CardSection {
                ForEach(macs) { mac in
                    NavigationLink(value: AppRoute.mac(mac.id)) { MacRow(mac: mac) }
                }
            } footer: {
                if !macs.isEmpty {
                    Text("質問づくり・説明・着手前の確認・最終 PR の対処・通知は、常時オンの Mac（司令塔）が受け持ちます")
                }
            }
        }
        .overlay {
            LoadStateOverlay(isEmpty: macs.isEmpty, empty: ContentUnavailableView("Mac が登録されていません", systemImage: "laptopcomputer"))
        }
        .pastelBackground()
        .navigationTitle("Mac")
        .toolbar { SectionToolbar() }
        .refreshable { await store.refresh() }
    }
}

/// Mac の 1 行
struct MacRow: View {
    let mac: Mac

    @ContentScale private var scale

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: mac.role == .commandCenter ? "macmini" : "laptopcomputer")
                .appFont(.title2)
                .foregroundStyle(mac.isOnline ? Theme.accent : Color.secondary)
                .frame(width: 40 * scale, height: 40 * scale)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mac.name).rowFont(.title)
                    Spacer(minLength: 8)
                    ConnectionBadge(mac: mac)
                }
                TagLabel(text: mac.role == .commandCenter ? "司令塔" : "ワーカー")
                DiskGauge(mac: mac)
                if let job = mac.jobs.first {
                    Label(job.title, systemImage: "hammer")
                        .rowFont(.detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let reason = mac.refusalReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .rowFont(.detail)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .compactRow()
        .accessibilityElement(children: .combine)
    }
}

/// オンラインか（最後の印からの時間）
struct ConnectionBadge: View {
    let mac: Mac

    @Environment(ClientStore.self) private var store

    var body: some View {
        switch mac.connection {
        case .online(let lastSeen):
            Label("オンライン · \(RelativeTime.string(lastSeen, now: store.currentDate()))", systemImage: "circle.fill")
                .appFont(.caption)
                .foregroundStyle(Theme.success)
                .labelStyle(DotLabelStyle())

        case .offline(let since):
            Label("オフライン · \(RelativeTime.duration(since: since, now: store.currentDate()))", systemImage: "circle.fill")
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(DotLabelStyle())
        }
    }
}

private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}

/// 空き容量のゲージ
struct DiskGauge: View {
    let mac: Mac

    var body: some View {
        Gauge(value: mac.usedFraction) {
            EmptyView()
        } currentValueLabel: {
            Text("空き \(ByteFormat.string(mac.freeBytes)) / \(ByteFormat.string(mac.totalBytes))")
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(mac.refusalReason == nil ? Theme.accent : Theme.warning)
        .appFont(.caption)
    }
}
