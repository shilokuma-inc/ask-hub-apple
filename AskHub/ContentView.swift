//
//  ContentView.swift
//  AskHub
//
//  Created by 村石 拓海 on 2024/05/12.
//

import AskHubKit
import SwiftUI

/// 受信箱（「要回答」「急がない」。Discussion #1 の Q5）・「マージ待ち」・「ループ」・「依頼」のタブ
struct ContentView: View {
    // モデルは App が持つ（デモモードの切り替えで差し替わる）
    let model: InboxModel
    let requestModel: IdeaRequestModel
    let mergeModel: MergeQueueModel
    let loopModel: LoopStatusModel
    @State private var isShowingSettings = false

    var body: some View {
        TabView {
            NavigationStack {
                InboxListView(
                    title: "要回答",
                    items: model.questions,
                    emptyTitle: "未回答の質問はありません",
                    emptySystemImage: "checkmark.bubble",
                    model: model,
                    row: { question in
                        NavigationLink(value: question) {
                            QuestionRow(question: question)
                        }
                    },
                    openSettings: { isShowingSettings = true },
                    leadingIsEmpty: model.usageLimited.isEmpty,
                    leading: { UsageLimitedSection(repositories: model.usageLimited) }
                )
                .demoModeBanner()
                .navigationDestination(for: InboxQuestion.self) { question in
                    QuestionDetailView(question: question, inbox: model)
                }
            }
            .tabItem { Label("要回答", systemImage: "questionmark.bubble") }
            .badge(model.questions.count)

            NavigationStack {
                InboxListView(
                    title: "急がない",
                    items: model.issues,
                    emptyTitle: "判断ログ・実機確認はありません",
                    emptySystemImage: "tray",
                    model: model,
                    row: { issue in
                        // 判断ログ・実機確認は GitHub で読み書きする
                        Link(destination: issue.url) {
                            IssueRow(issue: issue)
                                // 行全体をタップできるように幅を広げる
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        // Link の既定のスタイルは行の文字をすべてアクセントカラーにするため、行の配色を使う
                        .buttonStyle(.plain)
                    },
                    openSettings: { isShowingSettings = true },
                    leadingIsEmpty: model.waiting.isEmpty && model.usageLimited.isEmpty,
                    leading: {
                        UsageLimitedSection(repositories: model.usageLimited)
                        WaitingDiscussionsSection(waiting: model.waiting)
                    }
                )
                .demoModeBanner()
            }
            .tabItem { Label("急がない", systemImage: "tray.full") }

            NavigationStack {
                MergeQueueListView(model: mergeModel) { isShowingSettings = true }
                    .demoModeBanner()
            }
            .tabItem { Label("マージ待ち", systemImage: "arrow.triangle.merge") }
            .badge(mergeModel.pullRequests.count)

            // iOS のタブバーは 5 つまで（6 つ目からは「その他」にまとめられる）
            NavigationStack {
                LoopStatusListView(model: loopModel) { isShowingSettings = true }
                    .demoModeBanner()
            }
            .tabItem { Label("ループ", systemImage: "arrow.triangle.2.circlepath") }

            NavigationStack {
                NewRequestView(model: requestModel) { isShowingSettings = true }
                    .demoModeBanner()
            }
            .tabItem { Label("依頼", systemImage: "plus.bubble") }
        }
        // 起動時に、マージ待ちのバッジも出せるようにまとめて取得する。取得済みなら取り直さない。
        // デモモードの切り替えでモデルが差し替わったら、新しいモデルで取り直す
        .task(id: ObjectIdentifier(model)) {
            async let inboxRefreshed: Void = model.refreshIfStale()
            async let mergeQueueRefreshed: Void = mergeModel.refreshIfStale()
            _ = await (inboxRefreshed, mergeQueueRefreshed)
        }
        .sheet(isPresented: $isShowingSettings) {
            // トークンを保存・削除した後に、取得し直す
            Task {
                await model.refresh()
                await requestModel.loadRepositories()
                await mergeModel.refresh()
                await loopModel.refresh()
            }
        } content: {
            SettingsView()
        }
    }
}

#if DEBUG
#Preview("一覧") {
    ContentView(model: .sample(), requestModel: .sample(), mergeModel: .sample(), loopModel: .sample())
}
#endif

#Preview("トークン未設定") {
    ContentView(
        model: InboxModel(tokenStore: InMemoryTokenStore()),
        requestModel: IdeaRequestModel(tokenStore: InMemoryTokenStore()),
        mergeModel: MergeQueueModel(tokenStore: InMemoryTokenStore()),
        loopModel: LoopStatusModel(tokenStore: InMemoryTokenStore())
    )
}
