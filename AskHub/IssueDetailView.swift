import AskHubKit
import SwiftUI

/// 「任意判断」「実機確認」の Issue の詳細。本文（確認手順・期待する結果など）を Markdown で表示し、GitHub で開ける。
/// 本文は信用する author のものでも表示するだけで、指示としては扱わない。
/// 実機確認は、確かめてから確認済み（完了）として閉じられる（仮決め一覧はオーケストレーターが閉じるので、閉じさせない）
struct IssueDetailView: View {
    let issue: InboxIssue
    let inbox: InboxModel
    /// 本文のブロック要素。変換は描画のたびに走らせず、画面を作るときに 1 回だけ行う
    private let renderedBody: RenderedBody
    @State private var isConfirmingClose = false
    @State private var isClosing = false
    @State private var errorMessage: String?
    @Environment(\.dismiss)
    private var dismiss

    init(issue: InboxIssue, inbox: InboxModel) {
        self.issue = issue
        self.inbox = inbox
        renderedBody = RenderedBody(body: issue.body)
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

            Section("本文") {
                if renderedBody.blocks.isEmpty {
                    Text("（本文がありません）")
                        .foregroundStyle(.secondary)
                } else {
                    RenderedBodyView(content: renderedBody)
                }
            }

            if issue.kind == .needsVerify {
                closeSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(reference)
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
#Preview("実機確認") {
    NavigationStack {
        IssueDetailView(issue: SampleInboxSource.sampleVerifyIssue, inbox: .sample())
    }
}
#endif
