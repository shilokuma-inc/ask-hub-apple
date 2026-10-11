import AskHubKit
import Foundation
import Observation

/// 任意判断（仮決め一覧）の詳細画面の状態。項目ごとの承認・指示と、その結果を持つ（Discussion #349）
@MainActor
@Observable
final class DecisionLogDetailModel {
    /// 送る前に確かめる操作
    enum Action: Equatable {
        /// 採用のまま承認する（本文のチェックを付ける）
        case approve(DecisionLogItem)
        /// 別案・自由記述の指示を 1 件のコメントとして投稿する
        case instruct(DecisionInstruction, DecisionLogItem)

        var isApproval: Bool {
            if case .approve = self {
                return true
            }
            return false
        }

        var item: DecisionLogItem {
            switch self {
            case let .approve(item), let .instruct(_, item):
                item
            }
        }
    }

    /// 項目ごとの結果
    enum Outcome: Equatable {
        case approved
        /// 同じ行がすでに確認済みだった
        case alreadyApproved
        /// 指示を投稿した。コメントの URL
        case instructed(URL)
        case failed(String)
    }

    /// 承認・指示の後に読み直した本文を持つ Issue
    private(set) var issue: InboxIssue
    /// 本文を項目に分けたもの。本文が変わるたびに読み直す
    private(set) var items: [DecisionLogItem]
    /// 本文のブロック要素。変換は描画のたびに走らせず、本文が変わったときだけ行う
    private(set) var renderedBody: RenderedBody
    /// 項目ごとの補足（キーは `DecisionLogItem.text`）
    var notes: [String: String] = [:]
    /// 項目ごとの直前の結果（キーは `DecisionLogItem.text`）
    private(set) var outcomes: [String: Outcome] = [:]
    /// 承認しようとした行が本文に無かった（ループが書き換えた・消えた）ときの知らせ
    private(set) var notice: String?
    /// 送っている最中の操作。送っている間はほかの操作をさせない
    private(set) var sending: Action?

    init(issue: InboxIssue) {
        self.issue = issue
        items = DecisionLogItem.items(in: issue.body)
        renderedBody = RenderedBody(body: issue.body)
    }

    var isSending: Bool {
        sending != nil
    }

    /// 自由記述の補足（前後の空白を除く）
    func note(for item: DecisionLogItem) -> String {
        notes[item.text, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 補足を自由記述の指示として送れるか（自由記述は補足が必須）
    func canSendFreeText(for item: DecisionLogItem) -> Bool {
        !isSending && DecisionInstruction.freeText(note(for: item)).body(for: item) != nil
    }

    /// 別案の指示。補足があれば次の行に続ける
    func alternative(_ number: Int, for item: DecisionLogItem) -> DecisionInstruction {
        .alternative(number, note: note(for: item))
    }

    /// 確認ダイアログに出す、送る内容の説明
    func confirmation(for action: Action) -> String {
        switch action {
        case let .approve(item):
            let subject = item.decision.map { "#\($0.pullRequest)「\($0.subject)」" } ?? "この項目"
            return "\(subject)を採用のまま承認します。仮決め一覧の本文のチェックを付けます（コメントは投稿しません）"

        case let .instruct(instruction, item):
            return "次のコメントを仮決め一覧に投稿します\n\n\(instruction.body(for: item) ?? "")"
        }
    }

    func perform(_ action: Action, using inbox: InboxModel) async {
        guard !isSending else {
            return
        }
        sending = action
        notice = nil
        defer { sending = nil }
        let item = action.item
        do {
            switch action {
            case .approve:
                switch try await inbox.approve(item, in: issue) {
                case let .approved(body):
                    outcomes[item.text] = .approved
                    update(body: body)

                case let .alreadyApproved(body):
                    outcomes[item.text] = .alreadyApproved
                    update(body: body)

                case let .notFound(body):
                    outcomes[item.text] = nil
                    notice = "本文が変わっていたため承認しませんでした。最新の本文を表示しています。内容を確かめてからもう一度承認してください"
                    update(body: body)
                }

            case let .instruct(instruction, _):
                let url = try await inbox.post(instruction, for: item, to: issue)
                outcomes[item.text] = .instructed(url)
                notes[item.text] = nil
            }
        } catch {
            outcomes[item.text] = .failed(InboxModel.decisionMessage(for: error))
        }
    }

    private func update(body: String) {
        guard body != issue.body else {
            return
        }
        issue.body = body
        items = DecisionLogItem.items(in: body)
        renderedBody = RenderedBody(body: body)
    }
}
