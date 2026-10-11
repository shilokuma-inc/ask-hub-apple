import AskHubKit
import SwiftUI

/// 「ビルドの Mac」の節。ステータスタブの末尾と、設定画面の「ビルドの Mac」の画面で使う。
/// `build-hosts` の Issue が無ければ何も出さない（xcb を使わない環境では節ごと出ない）
struct BuildHostsSection: View {
    let status: BuildHostsStatus?

    var body: some View {
        if let status {
            Section {
                // 書き手がいないあいだは今の状態とは限らないので、状態の色を落とす
                let isStale = status.isStale(now: Date())
                ForEach(status.hostDisplays) { host in
                    BuildHostRow(host: host, isStale: isStale)
                }
            } header: {
                Text("ビルドの Mac")
            } footer: {
                footer(status)
            }
        }
    }

    private func footer(_ status: BuildHostsStatus) -> some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 2) {
            if status.isStale(now: now) {
                // 書き手（xcb を動かしている Mac のオーケストレーター）がいない。異常としては数えず、表示だけにする
                Label("30 分以上書き直されていません（書き手の Mac が止まっているかもしれません）", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            Text("確認: \(status.report.checkedAt, format: .relative(presentation: .named))")
            if let measuredAt = status.report.measuredAt {
                Text("load・空きメモリ: \(measuredAt, format: .relative(presentation: .named))")
            }
        }
    }
}

/// 「ビルドの Mac」の 1 台
struct BuildHostRow: View {
    let host: BuildHostDisplay
    /// 書き手が 30 分以上書き直していない（色を落とす）
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(host.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Label(host.statusText, systemImage: host.systemImage)
                    .font(.caption)
                    .foregroundStyle(isStale ? Color.secondary : host.tone.color)
            }
            if let loadText = host.loadText {
                Text(loadText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let runningText = host.runningText {
                Text(runningText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ForEach(host.jobTexts, id: \.self) { text in
                Label(text, systemImage: "hammer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("build-host")
    }
}

/// 直近 24 時間に別の Mac に移ったビルド。無ければ何も出さない
struct BuildMovesSection: View {
    let moves: [BuildMoveItem]

    var body: some View {
        if !moves.isEmpty {
            Section("直近 24 時間の移動") {
                ForEach(moves) { move in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(InboxSubject.shortRepository(move.repository))
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Text(move.resultText)
                                .font(.caption)
                                .foregroundStyle(move.succeeded == false ? .red : .secondary)
                        }
                        Text(move.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let finishedAt = move.finishedAt {
                            Text(finishedAt, format: .relative(presentation: .named))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("build-move")
                }
            }
        }
    }
}

extension BuildHostDisplay.Tone {
    var color: Color {
        switch self {
        case .available: .green
        case .unavailable: .red
        case .idle: .orange
        case .unknown: .secondary
        }
    }
}
