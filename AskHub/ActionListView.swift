import AskHubKit
import SwiftUI

/// 「要対応」タブ。上に「要回答」（Discussion の質問・PR の ask）、その下に「マージ待ち」（epic の最終 PR）を出す
struct ActionListView: View {
    let inbox: InboxModel
    let mergeQueue: MergeQueueModel
    let openSettings: () -> Void

    private var isEmpty: Bool {
        inbox.questions.isEmpty && mergeQueue.pullRequests.isEmpty
    }

    var body: some View {
        List {
            // 一覧の中身があるときは、空の表示の代わりにここで失敗を知らせる
            if !isEmpty {
                failureSection
            }
            if !inbox.questions.isEmpty {
                Section {
                    ForEach(inbox.questions) { question in
                        NavigationLink(value: question) {
                            QuestionRow(question: question)
                        }
                    }
                } header: {
                    header("要回答", count: inbox.questions.count, systemImage: "questionmark.bubble", tint: .orange)
                }
            }
            if !mergeQueue.pullRequests.isEmpty {
                Section {
                    ForEach(mergeQueue.pullRequests) { pullRequest in
                        NavigationLink(value: pullRequest) {
                            EpicPullRequestRow(pullRequest: pullRequest)
                        }
                    }
                } header: {
                    header("マージ待ち", count: mergeQueue.pullRequests.count, systemImage: "arrow.triangle.merge", tint: .purple)
                }
            }
        }
        .overlay {
            if isEmpty {
                emptyState
            }
        }
        .refreshable { await refresh() }
        .navigationTitle("要対応")
        .navigationDestination(for: InboxQuestion.self) { question in
            QuestionDetailView(question: question, inbox: inbox)
        }
        .navigationDestination(for: EpicPullRequest.self) { pullRequest in
            MergeDetailView(pullRequest: pullRequest, model: mergeQueue)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(inbox.isLoading || mergeQueue.isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("設定", systemImage: "gearshape", action: openSettings)
            }
        }
        // 起動時やフォアグラウンド復帰時に取得済みなら、タブを開いただけでは取り直さない
        .task(id: ObjectIdentifier(mergeQueue)) { await mergeQueue.refreshIfStale() }
    }

    private func refresh() async {
        async let inboxRefreshed: Void = inbox.refresh()
        async let mergeQueueRefreshed: Void = mergeQueue.refresh()
        _ = await (inboxRefreshed, mergeQueueRefreshed)
    }

    private func header(_ title: String, count: Int, systemImage: String, tint: Color) -> some View {
        Label {
            Text("\(title)（\(count) 件）")
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    private static func failure(of state: InboxModel.LoadState) -> String? {
        if case let .failed(message) = state { message } else { nil }
    }

    private static func failure(of state: MergeQueueModel.LoadState) -> String? {
        if case let .failed(message) = state { message } else { nil }
    }

    @ViewBuilder private var failureSection: some View {
        let messages = [Self.failure(of: inbox.state), Self.failure(of: mergeQueue.state)].compactMap(\.self)
        if !messages.isEmpty {
            Section {
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        switch inbox.state {
        case .idle, .loading:
            ProgressView()

        case .needsToken:
            ContentUnavailableView {
                Label("トークンが未設定です", systemImage: "key")
            } description: {
                Text("設定で GitHub の Personal Access Token を保存してください。トークンが無くても、サンプルデータで操作を試せます")
            } actions: {
                Button("設定を開く", action: openSettings)
                TryDemoButton()
            }

        case let .failed(message):
            ContentUnavailableView("取得できませんでした", systemImage: "exclamationmark.triangle", description: Text(message))

        case .loaded:
            ContentUnavailableView("対応が必要なものはありません", systemImage: "checkmark.circle")
        }
    }
}
