import AskHubKit
import SwiftUI

/// 仮決め一覧の項目ごとのセクション。未確認の項目は「採用のまま（承認）」「別案 N」と補足の欄から承認・指示を送れる（Discussion #349 の Q1〜Q3）
struct DecisionLogItemsSection: View {
    @Bindable var model: DecisionLogDetailModel
    /// 確かめてから送る操作
    @Binding var pendingAction: DecisionLogDetailModel.Action?
    var isEditingNote: FocusState<Bool>.Binding

    var body: some View {
        if let notice = model.notice {
            Section {
                Label(notice, systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
            }
        }

        if model.items.isEmpty {
            Section("仮決め") {
                Text("（仮決めの項目がありません）")
                    .foregroundStyle(.secondary)
            }
        }

        ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
            itemSection(item)
        }
    }

    @ViewBuilder
    private func itemSection(_ item: DecisionLogItem) -> some View {
        Section {
            if let decision = item.decision {
                LabeledContent("採用", value: decision.adopted)
                if !item.isChecked {
                    actionButton("採用のまま（承認）", action: .approve(item))
                    ForEach(Array(decision.alternatives.enumerated()), id: \.offset) { index, alternative in
                        actionButton("別案 \(index + 1): \(alternative)", action: .instruct(model.alternative(index + 1, for: item), item))
                    }
                } else if !decision.alternatives.isEmpty {
                    LabeledContent("別案", value: decision.alternatives.joined(separator: " / "))
                }
            } else {
                Text(item.text)
            }

            if item.isChecked {
                checkedLabel(item)
            } else {
                TextField(item.decision == nil ? "指示（自由記述）" : "補足（任意。補足だけを送るときは必須）", text: noteBinding(for: item), axis: .vertical)
                    .lineLimit(2...6)
                    .focused(isEditingNote)
                    .disabled(model.isSending)
                Button(item.decision == nil ? "指示を送る" : "補足だけを指示として送る") {
                    isEditingNote.wrappedValue = false
                    pendingAction = .instruct(.freeText(model.note(for: item)), item)
                }
                .disabled(!model.canSendFreeText(for: item))
            }

            if model.sending?.item == item {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            if let outcome = model.outcomes[item.text] {
                outcomeView(outcome)
            }
        } header: {
            Text(header(for: item))
        } footer: {
            if !item.isChecked {
                Text(footer(for: item))
            }
        }
    }

    private func actionButton(_ title: String, action: DecisionLogDetailModel.Action) -> some View {
        Button {
            isEditingNote.wrappedValue = false
            pendingAction = action
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .disabled(model.isSending)
    }

    @ViewBuilder
    private func checkedLabel(_ item: DecisionLogItem) -> some View {
        if let change = item.decision?.change {
            Label("変更済み: \(change)", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        } else {
            Label("承認済み", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func outcomeView(_ outcome: DecisionLogDetailModel.Outcome) -> some View {
        switch outcome {
        case .approved:
            Label("承認しました", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)

        case .alreadyApproved:
            Label("すでに承認済みでした", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)

        case let .instructed(url):
            Label("指示を送りました。ループが次の周回で読みます", systemImage: "paperplane.fill")
                .foregroundStyle(.green)
            Link("送ったコメントを GitHub で開く", destination: url)

        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func header(for item: DecisionLogItem) -> String {
        guard let decision = item.decision else {
            return "形式に合わない項目"
        }
        return "#\(decision.pullRequest) \(decision.subject)"
    }

    private func footer(for item: DecisionLogItem) -> String {
        guard let decision = item.decision else {
            return "この行を引用して、入力した指示をコメントします"
        }
        guard let first = decision.alternatives.first else {
            return "承認すると本文のチェックを付けます。変えたいときは補足に書いて送ります"
        }
        return "承認すると本文のチェックを付けます。別案を選ぶと「#\(decision.pullRequest) の「\(decision.subject)」は別案 1（\(first)）で」のようにコメントし、補足は次の行に続けます"
    }

    private func noteBinding(for item: DecisionLogItem) -> Binding<String> {
        Binding {
            model.notes[item.text, default: ""]
        } set: {
            model.notes[item.text] = $0
        }
    }
}
