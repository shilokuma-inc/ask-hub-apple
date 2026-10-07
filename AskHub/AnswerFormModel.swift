import AskHubKit
import Foundation
import Observation

/// 回答を確定した後に、ループをだれが回すか（Discussion #273 の Q2）
enum LoopRunner: Hashable, CaseIterable {
    /// 担当 PC のオーケストレーターが起動する（`ready-for-loop` を付ける）
    case orchestrator
    /// 手で回す（`manual-loop` を付ける。オーケストレーターは起動しない）
    case manual

    /// 回し方の選択肢に出す名前
    var title: String {
        switch self {
        case .orchestrator: "オーケストレーターで始める"
        case .manual: "手動で回す"
        }
    }

    /// 付けるラベル
    var label: AskHubLabel {
        switch self {
        case .orchestrator: .readyForLoop
        case .manual: .manualLoop
        }
    }
}

/// 質問の詳細画面の回答の入力と投稿の状態
@MainActor
@Observable
final class AnswerFormModel {
    let question: InboxQuestion
    /// 選んだ選択肢。選択肢の無い質問では使わない
    var choice: String?
    /// 自由記述（選択肢のある質問では補足）
    var note = ""
    /// 投稿したら、Discussion の回答を確定してループを始める（`ready-for-loop` を付ける）。
    /// 選べる質問（Discussion の最後の質問）では、設定画面の既定値（`LoopStartPreference`。初期値はオン）から始める
    /// （Issue #98・Discussion #244）。始める前には確認ダイアログを出す
    var startsLoopAfterPosting = false
    /// `startsLoopAfterPosting` のとき、ループをだれが回すか。毎回オーケストレーターから始める
    var loopRunner = LoopRunner.orchestrator
    /// 投稿を始めた時点の回し方。投稿中に選び直しても、確認したとおりの印を付ける（再試行でも使う）
    private(set) var postedRunner: LoopRunner?
    private(set) var isPosting = false
    private(set) var isPosted = false
    /// 回答は投稿できたが、ループを始める印を付けられなかった
    private(set) var loopStartFailed = false
    private(set) var errorMessage: String?

    init(question: InboxQuestion) {
        self.question = question
    }

    /// 画面を開いた時点の一覧で「投稿したらループを始める」を選べるなら、設定画面の既定値にしておく
    convenience init(question: InboxQuestion, inbox: InboxModel, defaults: UserDefaults = .standard) {
        self.init(question: question)
        startsLoopAfterPosting = canStartLoop(in: inbox) && LoopStartPreference.startsLoopAfterPosting(in: defaults)
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

    /// 「手動で回す」を選べるか。ループを始められ、Discussion の author が信用する author のとき
    /// （信用外の author の Discussion に付いた `manual-loop` はオーケストレーターが無視し、`ready-for-loop` を付けてしまう）
    func canRunManually(in inbox: InboxModel) -> Bool {
        canStartLoop(in: inbox) && inbox.isTrustedAuthor(of: question.subject)
    }

    /// 回答を投稿する。失敗したら入力を残してエラーを出す。
    /// `startsLoopAfterPosting` なら、投稿の後に Discussion へ `ready-for-loop`（手で回すなら `manual-loop`）を付ける。
    /// 回し方は投稿を始めた時点のものに固定する
    func post(using inbox: InboxModel) async {
        guard canPost else {
            return
        }
        let runner = startsLoopAfterPosting ? loopRunner : nil
        if runner == .manual && !canRunManually(in: inbox) {
            // 回答を投稿してから断ると、手で回すつもりの回答がオーケストレーターに拾われうるので、投稿する前に止める
            errorMessage = "この Discussion は信用する author が作ったものではないため、手動で回す印（manual-loop）は付けられません"
            return
        }
        postedRunner = runner
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
        if runner != nil {
            await startLoop(using: inbox)
        }
    }

    /// Discussion に `ready-for-loop`（手で回すなら `manual-loop`）を付ける。投稿の後に失敗したときの再試行にも使う。
    /// その時点の一覧で、この Discussion にほかの未回答の質問が無いことを確かめてから付ける
    func startLoop(using inbox: InboxModel) async {
        guard canStartLoop(in: inbox) else {
            loopStartFailed = false
            errorMessage = "この Discussion には、ほかに未回答の質問が \(inbox.remainingQuestions(besides: question)) 件あるため、ループを始めませんでした"
            return
        }
        let runner = postedRunner ?? loopRunner
        isPosting = true
        defer { isPosting = false }
        do {
            try await inbox.startLoop(for: question.subject, runner: runner)
            loopStartFailed = false
            errorMessage = nil
        } catch {
            loopStartFailed = true
            let mark = runner == .manual ? "手で回す印" : "ループを始める印"
            errorMessage = "回答は投稿しました。\(mark)（\(runner.label.rawValue)）を付けられませんでした: " + InboxModel.message(for: error)
        }
    }
}
