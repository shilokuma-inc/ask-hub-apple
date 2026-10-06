import AskHubKit
import SwiftUI

/// 「要回答」の 1 行
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

/// 「急がない」の 1 行
struct IssueRow: View {
    let issue: InboxIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(issue.kind.title, systemImage: issue.kind.systemImage)
                    .foregroundStyle(issue.kind.color)
                Text("\(InboxSubject.shortRepository(issue.repository))#\(issue.number)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(issue.updatedAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Text(issue.title)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

extension InboxSubject {
    /// 一覧に出す `repo#番号`。org は 1 つなので owner は省く
    var shortReference: String {
        "\(Self.shortRepository(repository))#\(number)"
    }

    static func shortRepository(_ fullName: String) -> String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }
}

extension InboxIssue.Kind {
    /// 「急がない」のセクションの並び（判断ログが上、実機確認が下）
    static let sectionOrder: [Self] = [.decisionLog, .needsVerify]

    var title: String {
        switch self {
        case .decisionLog:
            "判断ログ"

        case .needsVerify:
            "実機確認"
        }
    }

    var systemImage: String {
        switch self {
        case .decisionLog:
            "list.bullet.clipboard"

        case .needsVerify:
            "iphone"
        }
    }

    /// 種類を見分ける色。セクション見出しのアイコンと行のラベルに使う。システムカラーなのでライト・ダークの両方で読める
    var color: Color {
        switch self {
        case .decisionLog:
            .purple

        case .needsVerify:
            .orange
        }
    }
}

extension InboxIssue {
    /// 「急がない」の一覧を種類ごとのセクションに分ける。セクションの中の並びは `issues` のまま。0 件の種類は出さない
    static func sections(of issues: [InboxIssue]) -> [InboxListSection<InboxIssue>] {
        Kind.sectionOrder.compactMap { kind in
            let items = issues.filter { $0.kind == kind }
            guard !items.isEmpty else { return nil }
            return InboxListSection(
                id: kind.title,
                header: InboxListSection.Header(title: kind.title, systemImage: kind.systemImage, tint: kind.color),
                items: items
            )
        }
    }
}
