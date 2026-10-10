import AskHubKit
import SwiftUI

/// 「要対応」の要回答の 1 行
struct QuestionRow: View {
    let question: InboxQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: question.subject.kind == .discussion ? "bubble.left.and.bubble.right" : "arrow.triangle.pull")
                    .accessibilityLabel(question.subject.kind == .discussion ? "Discussion" : "Pull Request")
                Text(question.subject.shortReference)
                Spacer()
                Text(question.comment.createdAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(question.subject.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(question.summary)
                .foregroundStyle(.primary)
                .lineLimit(3)

            Text(question.marker.isFreeForm ? "自由記述" : "選択肢 \(question.marker.options.count) 件")
                .font(.caption)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }
}

/// 「任意判断」「実機確認」の 1 行。タブごとに種類が 1 つなので、種類のラベルは出さない
struct IssueRow: View {
    let issue: InboxIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(InboxSubject.shortRepository(issue.repository))#\(issue.number)")
                Spacer()
                Text(issue.updatedAt, format: .relative(presentation: .named))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(issue.displayTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 12) {
                // 目印の無い実機確認と仮決め一覧には、元の PR 番号を出さない
                if let pullRequest = issue.verifyMarker?.pullRequest {
                    Text("元の PR #\(pullRequest)")
                }
                // 何日放置されているかが分かるように、作成からの経過で出す
                Text("作成: \(issue.createdAt, format: .relative(presentation: .named))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension InboxSubject {
    /// 一覧に出す `repo#番号`。organization をまたいで同じ名前のリポジトリは置かない前提で、owner は省く
    var shortReference: String {
        "\(Self.shortRepository(repository))#\(number)"
    }

    static func shortRepository(_ fullName: String) -> String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }
}
