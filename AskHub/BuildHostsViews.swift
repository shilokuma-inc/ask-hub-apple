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

/// 設定画面から開く「ビルドの Mac」の画面。どの Mac でどのループのビルドが動いているかと、各 Mac の処理負荷を出す。
/// ステータスタブと同じ取得結果（`LoopStatusModel`）を使い、同じ節の部品を並べる
struct BuildHostsView: View {
    let model: LoopStatusModel

    var body: some View {
        List {
            BuildHostsSection(status: model.buildHosts)
            BuildMovesSection(moves: model.buildMoves(now: Date()))
        }
        .overlay {
            // 移動の記録だけがあるときは、空の表示で覆わない
            if model.buildHosts == nil, model.buildMoves(now: Date()).isEmpty {
                emptyState
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle("ビルドの Mac")
        .task { await model.refreshIfStale() }
    }

    /// 取得の状態で分ける（取得の失敗やトークン未設定を「Issue が無い」と言い換えない）
    @ViewBuilder private var emptyState: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()

        case .needsToken:
            ContentUnavailableView("トークンが未設定です", systemImage: "key")

        case let .failed(message):
            ContentUnavailableView("取得できませんでした", systemImage: "exclamationmark.triangle", description: Text(message))

        case .loaded:
            ContentUnavailableView(
                "ビルドの Mac の情報はありません",
                systemImage: "desktopcomputer",
                description: Text("xcb でビルドを振り分けている Mac のオーケストレーターが、設定の buildHosts を持つと、ここに出ます")
            )
        }
    }
}

extension BuildHostsStatus {
    /// 設定画面の入口に出す「3 台・実行中 1」。30 分以上書き直されていなければ「（古い）」を付ける
    func summaryText(now: Date) -> String {
        let running = report.jobs.count
        let text = running > 0 ? "\(report.hosts.count) 台・実行中 \(running)" : "\(report.hosts.count) 台"
        return isStale(now: now) ? text + "（古い）" : text
    }
}
