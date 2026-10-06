import AskHubKit
import SwiftUI

/// 「ループ」タブ。リポジトリごとのループの状態を出す（表示だけ）
struct LoopStatusListView: View {
    let model: LoopStatusModel
    let openSettings: () -> Void

    var body: some View {
        List(model.rows) { row in
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
        .overlay {
            if model.rows.isEmpty {
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

            if display.progressText != nil || display.lastActivityAt != nil {
                HStack(spacing: 6) {
                    if let progressText = display.progressText {
                        Text(progressText)
                    }
                    Spacer()
                    if let lastActivityAt = display.lastActivityAt {
                        Text("最後の動き: \(lastActivityAt, format: .relative(presentation: .named))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
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
