import AskHubKit
import SwiftUI

/// 「ループ」タブ。先頭に「上限で待機中」「ループの開始待ち」（どちらも空なら出さない）、その下にリポジトリごとのループの状態を出す（表示だけ）
struct LoopStatusListView: View {
    let model: LoopStatusModel
    let openSettings: () -> Void

    var body: some View {
        List {
            // 一覧の中身があるときは、空の表示の代わりにここで失敗を知らせる
            if case let .failed(message) = model.state, !model.isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            UsageLimitedSection(repositories: model.usageLimited)
            WaitingDiscussionsSection(waiting: model.waiting)
            if !model.rows.isEmpty {
                Section("リポジトリ") {
                    ForEach(model.rows) { row in
                        rowView(row)
                    }
                }
            }
        }
        .overlay {
            if model.isEmpty {
                emptyState
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle("ループ")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .disabled(model.isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("設定", systemImage: "gearshape", action: openSettings)
            }
        }
        // 起動時やフォアグラウンド復帰時に取得済みなら、タブを開いただけでは取り直さない
        // デモモードの切り替えでモデルが差し替わったら、新しいモデルで取り直す
        .task(id: ObjectIdentifier(model)) { await model.refreshIfStale() }
    }

    @ViewBuilder private func rowView(_ row: LoopStatusRow) -> some View {
        let display = row.display(now: Date())
        if let destination = display.destination {
            // ゴール元の Discussion（無ければ状態用の Issue）を GitHub で開く
            Link(destination: destination) {
                LoopStatusRowView(repository: row.repository, display: display)
                    // 行全体をタップできるように幅を広げる
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            // Link の既定のスタイルは行の文字をすべてアクセントカラーにするため、行の配色を使う
            .buttonStyle(.plain)
        } else {
            LoopStatusRowView(repository: row.repository, display: display)
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()

        case .needsToken:
            ContentUnavailableView {
                Label("トークンが未設定です", systemImage: "key")
            } actions: {
                Button("設定を開く", action: openSettings)
                TryDemoButton()
            }

        case let .failed(message):
            ContentUnavailableView("取得できませんでした", systemImage: "exclamationmark.triangle", description: Text(message))

        case .loaded:
            ContentUnavailableView(
                "ループの状態はありません",
                systemImage: "arrow.triangle.2.circlepath",
                description: Text("オーケストレーターが担当しているリポジトリが、ここに出ます")
            )
        }
    }
}

/// 「ループ」タブの 1 行
struct LoopStatusRowView: View {
    let repository: String
    let display: LoopStatusDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(InboxSubject.shortRepository(repository))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Label(display.statusText, systemImage: display.systemImage)
                    .font(.caption)
                    .foregroundStyle(display.tone.color)
            }

            if display.isStuck {
                Label(LoopStatusRow.stuckWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if let epic = display.epic {
                Text(epic)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            if let discussionText = display.discussionText {
                Text(discussionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let fraction = display.progressFraction, let stage = display.progressStage, let countText = display.progressCountText {
                HStack(spacing: 8) {
                    // 色だけに頼らないよう横に数を出すので、ゲージは読み上げない
                    ProgressGauge(fraction: fraction, color: stage.color, deferredFraction: display.progressDeferredFraction ?? 0)
                        .accessibilityHidden(true)
                    Text(countText)
                        .monospacedDigit()
                        .accessibilityLabel(display.progressText ?? countText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let lastActivityAt = display.lastActivityAt {
                Text("最後の動き: \(lastActivityAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 進捗の横長のゲージ。`fraction`（0〜1）の分だけ `color` で塗り、その後ろに `deferredFraction` の分だけ保留の色で積む
struct ProgressGauge: View {
    let fraction: Double
    let color: Color
    /// 保留で閉じたタスクの割合。0 なら保留を区別しない（積まない）
    var deferredFraction: Double = 0

    /// ゲージの太さ
    static let height: CGFloat = 6
    /// 保留の色。段階の色（`ProgressStage.color`）・残り（`.quaternary`）のどちらとも見分けられる灰色にする
    static let deferredColor: Color = .gray

    var body: some View {
        let done = min(max(fraction, 0), 1)
        let deferred = min(max(deferredFraction, 0), 1 - done)
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    // 保留を「完了 + 保留」の長さで敷き、その上に完了を重ねる（どちらの端も丸くなる）
                    ZStack(alignment: .leading) {
                        if deferred > 0 {
                            Capsule()
                                .fill(Self.deferredColor)
                                .frame(width: proxy.size.width * (done + deferred))
                        }
                        Capsule()
                            .fill(color)
                            .frame(width: proxy.size.width * done)
                    }
                }
            }
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
    }
}

/// 「ループの開始待ち」の節。担当 PC のいないリポジトリは「担当 PC なし」と出す
struct WaitingDiscussionsSection: View {
    let waiting: [WaitingDiscussion]

    var body: some View {
        if !waiting.isEmpty {
            Section {
                ForEach(waiting) { discussion in
                    Link(destination: discussion.subject.url) {
                        WaitingDiscussionRow(discussion: discussion)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("ループの開始待ち")
            } footer: {
                Text("担当 PC のオーケストレーターが 30 分以上確認していないリポジトリは「担当 PC なし」と出します")
            }
        }
    }
}

struct WaitingDiscussionRow: View {
    let discussion: WaitingDiscussion

    var body: some View {
        // 相対時刻を出さないので、表示のたびの時刻で判定すればよい
        let isAssigned = discussion.isAssigned(now: Date())
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(discussion.subject.shortReference)
                    .foregroundStyle(.secondary)
                Spacer()
                if let until = discussion.usageLimitedUntil, discussion.isUsageLimited(now: Date()) {
                    Label(
                        "上限で待機中（\(UsageLimitedRepository.resumeText(until: until, now: Date()))）",
                        systemImage: "moon.zzz.fill"
                    )
                    .foregroundStyle(.orange)
                } else if isAssigned {
                    Label("担当 PC が起動します", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                } else {
                    Label("担当 PC なし", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)

            Text(discussion.subject.title)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// 「上限で待機中」の節。担当 PC が Claude の利用上限で止まっているリポジトリと、再開の時刻を出す
struct UsageLimitedSection: View {
    let repositories: [UsageLimitedRepository]

    var body: some View {
        if !repositories.isEmpty {
            Section {
                ForEach(repositories) { repository in
                    HStack(spacing: 6) {
                        Label(repository.repository, systemImage: "moon.zzz.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text(repository.resumeText(now: Date()))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            } header: {
                Text("上限で待機中")
            } footer: {
                Text("担当 PC の Claude が利用上限に達しています。再開の時刻を過ぎると、止まっていたループを自動で再開します")
            }
        }
    }
}

extension LoopStatusDisplay.Tone {
    var color: Color {
        switch self {
        case .active:
            .blue

        case .needsAnswer:
            .purple

        case .paused:
            // 「上限で待機中」の欄と同じ色
            .orange

        case .failure:
            .red

        case .done:
            .green

        case .inactive:
            .secondary
        }
    }
}

extension LoopStatusDisplay.ProgressStage {
    /// ゲージの色。しきい値は `ProgressStage.init(fraction:)`、色はここの 1 か所で決める。
    /// 始まったばかりの段階が「異常」に見えないよう、赤（`Tone.failure`）・橙（`Tone.paused`）は使わない
    var color: Color {
        switch self {
        case .starting:
            .indigo

        case .halfway:
            .blue

        case .nearlyDone:
            .teal

        case .completed:
            .green
        }
    }
}

#if DEBUG
#Preview("ループ") {
    NavigationStack {
        LoopStatusListView(model: .sample()) {}
    }
}
#endif

#Preview("トークン未設定") {
    NavigationStack {
        LoopStatusListView(model: LoopStatusModel(tokenStore: InMemoryTokenStore())) {}
    }
}
