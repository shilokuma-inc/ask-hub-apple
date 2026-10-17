import AskHubKit
import Foundation
import Observation

/// 「マージ待ち」の詳細に出す、最終 PR の CodeRabbit の未解決の指摘（Discussion #498 の案 4）
@MainActor
@Observable
final class CodeRabbitFindingsModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        /// 直前の取得に失敗した。一覧は前回の結果を残す
        case failed(String)
    }

    /// 一覧の 1 行。本文の変換は描画のたびに走らせず、取得したときに 1 回だけ行う
    struct Row: Identifiable, Equatable {
        let thread: CodeRabbitReviewThread
        let renderedBody: RenderedBody

        var id: String {
            thread.id
        }

        /// `path:line`（行が無ければパスだけ）
        var location: String {
            thread.line.map { "\(thread.path):\($0)" } ?? thread.path
        }
    }

    let pullRequest: EpicPullRequest
    private(set) var rows: [Row] = []
    private(set) var state = LoadState.idle
    /// この画面で「ループに直させる」を投稿した指摘（スレッドの id → 投稿したコメントの URL）
    private(set) var instructed: [String: URL] = [:]

    init(pullRequest: EpicPullRequest) {
        self.pullRequest = pullRequest
    }

    var isLoading: Bool {
        state == .loading
    }

    /// 指摘 1 件を直させる指示を最終 PR に投稿する。失敗したら説明を返す（投稿できたら `nil`）
    func instruct(fixing row: Row, note: String, using model: MergeQueueModel) async -> String? {
        do {
            instructed[row.id] = try await model.instructLoop(fixing: row.thread, note: note, in: pullRequest)
            return nil
        } catch {
            return MergeQueueModel.message(for: error)
        }
    }

    /// 指摘を取り直す
    func load(using model: MergeQueueModel) async {
        guard !isLoading else {
            return
        }
        let previous = state
        state = .loading
        do {
            let threads = try await model.codeRabbitThreads(of: pullRequest)
            rows = threads.map { Row(thread: $0, renderedBody: RenderedBody(body: $0.finding.body)) }
            state = .loaded
        } catch {
            // 画面から外れて取得が打ち切られた。失敗とは表示せず、次に表示したときに取り直せるようにする
            if Task.isCancelled || error is CancellationError {
                state = previous == .loading ? .idle : previous
                return
            }
            state = .failed(MergeQueueModel.message(for: error))
        }
    }
}
