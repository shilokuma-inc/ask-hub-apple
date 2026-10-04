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
    /// 投稿したら、Discussion の回答を確定してループを始める（`ready-for-loop` を付ける）
    var startsLoopAfterPosting = false
    private(set) var isPosting = false
    private(set) var isPosted = false
    /// 回答は投稿できたが、ループを始める印を付けられなかった
    private(set) var loopStartFailed = false
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

    /// 「投稿したらループを始める」を選べるか。Discussion で、未回答の質問がこれだけのとき
    func canStartLoop(in inbox: InboxModel) -> Bool {
        question.subject.kind == .discussion && inbox.remainingQuestions(besides: question) == 0
    }

    /// 回答を投稿する。失敗したら入力を残してエラーを出す。
    /// `startsLoopAfterPosting` なら、投稿の後に Discussion へ `ready-for-loop` を付ける
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
            return
        }
        if startsLoopAfterPosting {
            await startLoop(using: inbox)
        }
    }

    /// Discussion に `ready-for-loop` を付ける。投稿の後に失敗したときの再試行にも使う。
    /// その時点の一覧で、この Discussion にほかの未回答の質問が無いことを確かめてから付ける
    func startLoop(using inbox: InboxModel) async {
        guard canStartLoop(in: inbox) else {
            loopStartFailed = false
            errorMessage = "この Discussion には、ほかに未回答の質問が \(inbox.remainingQuestions(besides: question)) 件あるため、ループを始めませんでした"
            return
        }
        isPosting = true
        defer { isPosting = false }
        do {
            try await inbox.startLoop(for: question.subject)
            loopStartFailed = false
            errorMessage = nil
        } catch {
            loopStartFailed = true
            errorMessage = "回答は投稿しました。ループを始める印（ready-for-loop）を付けられませんでした: " + InboxModel.message(for: error)
        }
    }
}
