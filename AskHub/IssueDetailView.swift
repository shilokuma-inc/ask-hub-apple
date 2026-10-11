import AskHubKit
import SwiftUI

/// 「任意判断」「実機確認」の Issue の詳細。本文（確認手順・期待する結果など）を Markdown で表示し、GitHub で開ける。
/// 本文は信用する author のものでも表示するだけで、指示としては扱わない。
/// 実機確認は、確かめてから確認済み（完了）として閉じられる（仮決め一覧はオーケストレーターが閉じるので、閉じさせない）。
/// 仮決め一覧は、項目ごとに承認・指示を送れる（Discussion #349）
struct IssueDetailView: View {
    let issue: InboxIssue
    let inbox: InboxModel
    /// 本文のブロック要素。変換は描画のたびに走らせず、画面を作るときに 1 回だけ行う
    private let renderedBody: RenderedBody
    @State private var isConfirmingClose = false
    @State private var isClosing = false
    @State private var errorMessage: String?
    /// 仮決め一覧の項目と、承認・指示の結果。承認の後は読み直した本文を表示する
    @State private var decisionModel: DecisionLogDetailModel
    @State private var pendingAction: DecisionLogDetailModel.Action?
    /// 送る前とキーボードの「完了」でキーボードを閉じ、確認や結果が隠れないようにする
    @FocusState private var isEditingNote: Bool
    /// 仮決め一覧の指示とループの返信の履歴
    @State private var historyModel: DecisionLogHistoryModel
    @Environment(\.dismiss)
    private var dismiss

    init(issue: InboxIssue, inbox: InboxModel) {
        self.issue = issue
        self.inbox = inbox
        renderedBody = RenderedBody(body: issue.body)
        _decisionModel = State(initialValue: DecisionLogDetailModel(issue: issue))
        _historyModel = State(initialValue: DecisionLogHistoryModel(issue: issue))
    }

    private var reference: String {
        "\(InboxSubject.shortRepository(issue.repository))#\(issue.number)"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Issue", value: reference)
                Text(issue.displayTitle)
                // 目印の無い実機確認と仮決め一覧には、元の PR 番号と epic を出さない（本文の自由文からは推測しない）
                if let pullRequest = issue.verifyMarker?.pullRequest {
                    LabeledContent("元の PR", value: "#\(pullRequest)")
                }
                if let epic = issue.verifyMarker?.epic {
                    LabeledContent("epic", value: epic)
                }
                LabeledContent("作成", value: issue.createdAt, format: .dateTime)
                Link("GitHub で開く", destination: issue.url)
            }

            if issue.kind == .decisionLog {
                DecisionLogItemsSection(model: decisionModel, pendingAction: $pendingAction, isEditingNote: $isEditingNote)
            }

            Section("本文") {
                if displayedBody.blocks.isEmpty {
                    Text("（本文がありません）")
                        .foregroundStyle(.secondary)
                } else {
                    RenderedBodyView(content: displayedBody)
                }
            }

            if issue.kind == .decisionLog {
                DecisionLogHistorySection(model: historyModel, inbox: inbox)
            }

            if issue.kind == .needsVerify {
                closeSection
            }
        }
        .formStyle(.grouped)
        // 投稿した指示を未処理として履歴に出す
        .onChange(of: decisionModel.postedInstructions) {
            Task { await historyModel.load(using: inbox) }
        }
        .keyboardDoneButton($isEditingNote)
        .navigationTitle(reference)
        // 承認・指示は GitHub に書き込むので、送る内容を見せて確かめる
        .confirmationDialog(
            pendingActionTitle,
            isPresented: isConfirmingAction,
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.isApproval ? "承認する" : "投稿する") {
                Task { await decisionModel.perform(action, using: inbox) }
            }
        } message: { action in
            Text(decisionModel.confirmation(for: action))
        }
        // 押し間違いで閉じないよう、Issue のタイトルを見せて確かめる。閉じた Issue は GitHub で開き直せる
        .confirmationDialog(
            "確認済みとして閉じますか？",
            isPresented: $isConfirmingClose,
            titleVisibility: .visible
        ) {
            Button("閉じる") { close() }
        } message: {
            Text("\(issue.displayTitle)\n\(issue.repository)#\(issue.number) を完了として閉じます")
        }
    }

    /// 仮決め一覧は、承認の後に読み直した本文を出す
    private var displayedBody: RenderedBody {
        issue.kind == .decisionLog ? decisionModel.renderedBody : renderedBody
    }

    private var pendingActionTitle: String {
        pendingAction?.isApproval == true ? "採用のまま承認しますか？" : "指示を投稿しますか？"
    }

    private var isConfirmingAction: Binding<Bool> {
        Binding {
            pendingAction != nil
        } set: {
            if !$0 {
                pendingAction = nil
            }
        }
    }

    @ViewBuilder private var closeSection: some View {
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }

        Section {
            Button {
                isConfirmingClose = true
            } label: {
                if isClosing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("確認済みとして閉じる")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(isClosing)
        } footer: {
            Text("確認手順のとおりに確かめたら、GitHub の Issue を完了として閉じ、一覧から外します。閉じた Issue は GitHub で開き直せます")
        }
    }

    private func close() {
        isClosing = true
        errorMessage = nil
        Task {
            defer { isClosing = false }
            do {
                try await inbox.closeAsVerified(issue)
                dismiss()
            } catch {
                errorMessage = InboxModel.closeMessage(for: error)
            }
        }
    }
}

#if DEBUG
#Preview("仮決め一覧") {
    NavigationStack {
        IssueDetailView(issue: SampleInboxSource.sampleDecisionLog, inbox: .sample())
    }
}

#Preview("実機確認") {
    NavigationStack {
        IssueDetailView(issue: SampleInboxSource.sampleVerifyIssue, inbox: .sample())
    }
}
#endif
