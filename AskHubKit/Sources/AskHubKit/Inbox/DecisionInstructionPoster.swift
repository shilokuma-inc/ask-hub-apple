import Foundation

/// 仮決めの 1 項目への指示（別案・自由記述）。取り決めは `docs/protocol.md` の「アプリからの指示（項目ごとのコメント）」
public enum DecisionInstruction: Sendable, Equatable {
    /// 別案を選ぶ。番号は `（別案: …）` の中の並び順で 1 から数える。補足は空でもよい
    case alternative(Int, note: String)
    /// 自由記述。補足は必須
    case freeText(String)

    /// 指示のコメントの本文。項目に合わない指示（形式に合わない項目への別案・範囲外の番号・空の自由記述・目印を含む補足）は `nil`
    public func body(for item: DecisionLogItem) -> String? {
        let firstLine: String
        let note: String
        switch self {
        case let .alternative(number, rawNote):
            guard let decision = item.decision, decision.alternatives.indices.contains(number - 1) else {
                return nil
            }
            firstLine = "#\(decision.pullRequest) の「\(decision.subject)」は別案 \(number)（\(decision.alternatives[number - 1])）で"
            note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)

        case let .freeText(rawNote):
            note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else {
                return nil
            }
            if let decision = item.decision {
                firstLine = "#\(decision.pullRequest) の「\(decision.subject)」について:"
            } else {
                firstLine = "> \(item.text)"
            }
        }
        let body = note.isEmpty ? firstLine : "\(firstLine)\n\(note)"
        // 目印を含むと、ループの返信とみなされて指示が処理済みに見える
        guard !DecisionLogMarker.all.contains(where: body.contains) else {
            return nil
        }
        return body
    }
}

/// 指示を投稿できないときのエラー
public enum DecisionInstructionError: Error, Equatable, Sendable {
    /// 仮決め一覧以外の Issue には投稿しない
    case notDecisionLog
    /// 指示が項目に合わない（`DecisionInstruction.body(for:)` が `nil`）
    case invalidInstruction
}

/// 仮決めの項目への指示を投稿する。テストでは差し替える
public protocol DecisionInstructionPosting: Sendable {
    /// 仮決め一覧に、1 項目への指示を 1 件のコメントとして投稿し、投稿したコメントの URL を返す
    func post(_ instruction: DecisionInstruction, for item: DecisionLogItem, to issue: InboxIssue) async throws -> URL
}

/// GitHub の REST API で指示を投稿する（Discussion #349 の Q3）。トークンには Issues の書き込み権限が要る。
/// 本文のチェックは変えない（ループが指示を処理するときに ` → 変更: …` を追記してチェックを付ける）
public struct GitHubDecisionInstructionPoster: DecisionInstructionPosting {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func post(_ instruction: DecisionInstruction, for item: DecisionLogItem, to issue: InboxIssue) async throws -> URL {
        guard issue.kind == .decisionLog else {
            throw DecisionInstructionError.notDecisionLog
        }
        guard let body = instruction.body(for: item) else {
            throw DecisionInstructionError.invalidInstruction
        }
        let comment = try await client.send(
            "POST",
            "repos/\(issue.repository)/issues/\(issue.number)/comments",
            body: ["body": body],
            as: PostedComment.self
        )
        return comment.htmlURL
    }
}

private struct PostedComment: Decodable {
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case htmlURL = "html_url"
    }
}
