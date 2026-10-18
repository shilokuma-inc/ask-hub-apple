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
        // 同じ Discussion の質問に同じ色のバーを付ける（Discussion #418 の Q1）。PR の ask には付けない（Q2）。
        // 行の中身はずらさず、左の余白（iOS / macOS とも 16pt ほど）に置く。色だけに頼らないよう `repo#番号` は残し、バーは読み上げない
        .overlay(alignment: .leading) {
            if let color = question.subject.groupColor {
                Capsule()
                    .fill(color)
                    .frame(width: 4)
                    .offset(x: -10)
                    .accessibilityHidden(true)
            }
        }
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
        // 同じリポジトリの Issue に同じ色の線を付ける（Discussion #563 の Q1・Q4）。形は `QuestionRow` の線と同じ。
        // 色だけに頼らないよう `repo#番号` は残し、線は読み上げない
        .overlay(alignment: .leading) {
            if let color = issue.repositoryColor {
                Capsule()
                    .fill(color)
                    .frame(width: 4)
                    .offset(x: -10)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// 一覧の行の左端の線に使う色。ライト / ダークの両方で見分けられるシステムカラー。
/// 数や順番を変えると、どの Discussion・リポジトリがどの色になるかも変わる
private let rowLinePalette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

extension InboxIssue {
    /// 「任意判断」「実機確認」の行の左端に出す、リポジトリごとの色。
    /// 色はリポジトリ名から決まるので、取り直しても起動し直しても変わらない
    var repositoryColor: Color? {
        repositoryColorIndex(paletteCount: rowLinePalette.count).map { rowLinePalette[$0] }
    }
}

extension InboxSubject {
    /// 要回答の行の左端に出す、Discussion ごとの色。PR の ask には付けないので `nil`。
    /// 色は node id から決まるので、取り直しても起動し直しても変わらない
    var groupColor: Color? {
        colorIndex(paletteCount: rowLinePalette.count).map { rowLinePalette[$0] }
    }

    /// 一覧に出す `repo#番号`。organization をまたいで同じ名前のリポジトリは置かない前提で、owner は省く
    var shortReference: String {
        "\(Self.shortRepository(repository))#\(number)"
    }

    static func shortRepository(_ fullName: String) -> String {
        fullName.split(separator: "/").last.map(String.init) ?? fullName
    }
}
