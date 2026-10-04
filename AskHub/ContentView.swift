//
//  ContentView.swift
//  AskHub
//
//  Created by 村石 拓海 on 2024/05/12.
//

import AskHubKit
import SwiftUI

/// 受信箱。「要回答」と「急がない」のタブに分ける（Discussion #1 の Q5）
struct ContentView: View {
    @State private var model: InboxModel
    @State private var isShowingSettings = false

    init(model: InboxModel = .launchDefault()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        TabView {
            NavigationStack {
                InboxListView(
                    title: "要回答",
                    items: model.questions,
                    emptyTitle: "未回答の質問はありません",
                    emptySystemImage: "checkmark.bubble",
                    model: model,
                    url: \.comment.url,
                    row: { QuestionRow(question: $0) },
                    openSettings: { isShowingSettings = true }
                )
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
                    url: \.url,
                    row: { IssueRow(issue: $0) },
                    openSettings: { isShowingSettings = true }
                )
            }
            .tabItem { Label("急がない", systemImage: "tray.full") }
        }
        .task { await model.refresh() }
        .sheet(isPresented: $isShowingSettings) {
            // トークンを保存・削除した後に、取得し直す
            Task { await model.refresh() }
        } content: {
            SettingsView()
        }
    }
}

#if DEBUG
#Preview("一覧") {
    ContentView(model: .sample())
}
#endif

#Preview("トークン未設定") {
    ContentView(model: InboxModel(tokenStore: InMemoryTokenStore()))
}
