import AskHubKit
import Foundation
import Observation

/// 質問の詳細画面の回答の入力と投稿の状態
@MainActor
@Observable
final class AnswerFormModel {
    let question: InboxQuestion
    /// 選んだ選択肢。選択肢の無い質問では使わない
    var choice: String?
    /// 自由記述（選択肢のある質問では補足）
    var note = ""
    private(set) var isPosting = false
    private(set) var isPosted = false
    private(set) var errorMessage: String?

    init(question: InboxQuestion) {
        self.question = question
    }

    /// 投稿する回答（`docs/protocol.md` の「回答の形式」）
    var answer: Answer {
        question.marker.isFreeForm ? Answer(note: note) : Answer(choice: choice, note: note)
    }

    var canPost: Bool {
        !isPosting && !isPosted && answer.isValid(for: question.marker)
    }

    /// 回答を投稿する。失敗したら入力を残してエラーを出す
    func post(using inbox: InboxModel) async {
        guard canPost else {
            return
        }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }
        do {
            try await inbox.post(answer, to: question)
            isPosted = true
        } catch {
            errorMessage = InboxModel.message(for: error)
        }
    }
}
