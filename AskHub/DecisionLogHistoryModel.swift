import AskHubKit
import Foundation
import Observation

/// 任意判断（仮決め一覧）の詳細画面に出す、指示とループの返信の履歴（Discussion #349）
@MainActor
@Observable
final class DecisionLogHistoryModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// 直前の取得に失敗した。履歴は前回の結果を残す
        case failed(String)
    }

    /// 履歴の 1 行。本文の変換は描画のたびに走らせず、取得したときに 1 回だけ行う
    struct Row: Identifiable, Equatable {
        let entry: DecisionLogHistory.Entry
        let renderedBody: RenderedBody

        var id: Int {
            entry.id
        }
    }

    let issue: InboxIssue
    /// 古い順（作成順）の履歴
    private(set) var rows: [Row] = []
    /// ループがまだ処理していない指示の数
    private(set) var unprocessedCount = 0
    private(set) var state = LoadState.idle

    init(issue: InboxIssue) {
        self.issue = issue
    }

    var isLoading: Bool {
        state == .loading
    }

    func load(using inbox: InboxModel) async {
        guard !isLoading else {
            return
        }
        state = .loading
        do {
            let history = try await inbox.decisionHistory(for: issue)
            rows = history.entries.map { Row(entry: $0, renderedBody: RenderedBody(body: $0.comment.body)) }
            unprocessedCount = history.unprocessedInstructions.count
            state = .loaded
        } catch {
            state = .failed(InboxModel.message(for: error))
        }
    }
}
