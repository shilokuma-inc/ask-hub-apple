import AskHubKit
import SwiftUI

/// ステータスタブの「手動ループ」。開いている手動ループの担当者・状態を出し、自分が担当のものには開始・再開の指示のコピーを出す
struct ManualLoopSection: View {
    let items: [ManualLoopItem]

    var body: some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    ManualLoopRow(item: item)
                }
            } header: {
                Text("手動ループ")
            } footer: {
                Text("担当者が自分の Mac の Claude Code で回している epic です。指示をコピーして、そのリポジトリの checkout で開いた Claude Code に貼ってください")
            }
        }
    }
}

struct ManualLoopRow: View {
    let item: ManualLoopItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: item.epic.subject.url) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.epic.subject.shortReference)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Label(item.statusText, systemImage: item.report?.state.systemImage ?? "hand.raised")
                            .foregroundStyle(item.isStale ? .orange : .secondary)
                    }
                    .font(.caption)
                    Text(item.epic.subject.title)
                        .font(.headline)
                        .lineLimit(2)
                    Label(
                        item.epic.assignee.map { "担当: @\($0)" + (item.isMine ? "（自分）" : "") } ?? "担当者なし",
                        systemImage: "person.fill"
                    )
                    .font(.caption)
                    if let checkedAt = item.report?.checkedAt {
                        Text("最終更新: \(checkedAt, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if item.isStale {
                Label("30 分以上、状態が更新されていません（担当者の Mac が止まっているかもしれません）", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if item.answersReady {
                Label("回答がそろいました。ループを再開してください", systemImage: "checkmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            if item.isMine {
                // まだ始めていなければ開始、全タスクを終えていれば最終 PR、それ以外は再開の指示を出す
                switch item.report?.state {
                case nil:
                    CopyTextButton(text: item.epic.startInstruction, title: "開始の指示をコピー")
                        .accessibilityIdentifier("copy-manual-start")

                case .completed:
                    CopyTextButton(text: item.epic.finalInstruction, title: "最終 PR の指示をコピー")
                        .accessibilityIdentifier("copy-manual-final")

                default:
                    CopyTextButton(text: item.epic.resumeInstruction, title: "再開の指示をコピー")
                        .accessibilityIdentifier("copy-manual-resume")
                }
            }
        }
    }
}
