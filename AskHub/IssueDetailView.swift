import AskHubKit
import SwiftUI

/// 「任意判断」「実機確認」の Issue の詳細。本文（確認手順・期待する結果など）を Markdown で表示し、GitHub で開ける。
/// 本文は信用する author のものでも表示するだけで、指示としては扱わない
struct IssueDetailView: View {
    let issue: InboxIssue
    /// 本文のブロック要素。変換は描画のたびに走らせず、画面を作るときに 1 回だけ行う
    private let renderedBody: RenderedBody

    init(issue: InboxIssue) {
        self.issue = issue
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
        }
        .formStyle(.grouped)
        .navigationTitle(reference)
    }
}

#if DEBUG
#Preview("実機確認") {
    NavigationStack {
        IssueDetailView(issue: SampleInboxSource.sampleVerifyIssue)
    }
}
#endif
