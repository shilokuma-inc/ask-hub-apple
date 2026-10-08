//
//  ContentView.swift
//  AskHub
//
//  Created by 村石 拓海 on 2024/05/12.
//

import AskHubKit
import SwiftUI

/// アプリのタブ。左から「依頼」「要対応」「任意判断」「ステータス」「実機確認」。開いたときは「要対応」を出す
enum AppTab: Hashable {
    case request
    case action
    case decisions
    case status
    case verification
}

/// 依頼・要対応（要回答とマージ待ち）・任意判断（仮決め一覧）・ステータス（ループの状態）・実機確認のタブ
struct ContentView: View {
    // モデルは App が持つ（デモモードの切り替えで差し替わる）
    let model: InboxModel
    let requestModel: IdeaRequestModel
    let mergeModel: MergeQueueModel
    let loopModel: LoopStatusModel
    @State private var isShowingSettings = false
    @State private var selection = AppTab.action

    var body: some View {
        // iOS のタブバーは 5 つまで（6 つ目からは「その他」にまとめられる）
        TabView(selection: $selection) {
            NavigationStack {
                NewRequestView(model: requestModel) { isShowingSettings = true }
                    .demoModeBanner()
            }
            .tabItem { Label("依頼", systemImage: "plus.bubble") }
            .tag(AppTab.request)

            NavigationStack {
                ActionListView(inbox: model, mergeQueue: mergeModel) { isShowingSettings = true }
                    .demoModeBanner()
            }
            .tabItem { Label("要対応", systemImage: "exclamationmark.bubble") }
            .badge(model.questions.count + mergeModel.pullRequests.count)
            .tag(AppTab.action)

            NavigationStack {
                issueList(
                    title: "任意判断",
                    kind: .decisionLog,
                    emptyTitle: "任意判断（仮決め一覧）はありません",
                    emptySystemImage: "checklist"
                )
            }
            .tabItem { Label("任意判断", systemImage: "checklist") }
            .badge(model.issues.filter { $0.kind == .decisionLog }.count)
            .tag(AppTab.decisions)

            NavigationStack {
                LoopStatusListView(model: loopModel, requestModel: requestModel) { isShowingSettings = true }
                    .demoModeBanner()
            }
            .tabItem { Label("ステータス", systemImage: "arrow.triangle.2.circlepath") }
            // 異常（異常終了・長く動きが無い・担当 PC がいない進行中の epic・状態が途絶えた手動ループ）だけを数える
            .badge(loopModel.abnormalCount(now: Date()))
            .tag(AppTab.status)

            NavigationStack {
                issueList(
                    title: "実機確認",
                    kind: .needsVerify,
                    emptyTitle: "実機確認はありません",
                    emptySystemImage: "iphone"
                )
            }
            .tabItem { Label("実機確認", systemImage: "iphone") }
            .badge(model.issues.filter { $0.kind == .needsVerify }.count)
            .tag(AppTab.verification)
        }
        // 起動時に、要対応・ステータスのバッジも出せるようにまとめて取得する。取得済みなら取り直さない。
        // デモモードの切り替えでモデルが差し替わったら、新しいモデルで取り直す
        .task(id: ObjectIdentifier(model)) {
            async let inboxRefreshed: Void = model.refreshIfStale()
            async let mergeQueueRefreshed: Void = mergeModel.refreshIfStale()
            async let loopRefreshed: Void = loopModel.refreshIfStale()
            _ = await (inboxRefreshed, mergeQueueRefreshed, loopRefreshed)
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

    /// 任意判断・実機確認の一覧。Issue は GitHub で読み書きする
    private func issueList(title: String, kind: InboxIssue.Kind, emptyTitle: String, emptySystemImage: String) -> some View {
        InboxListView(
            title: title,
            items: model.issues.filter { $0.kind == kind },
            emptyTitle: emptyTitle,
            emptySystemImage: emptySystemImage,
            model: model,
            row: { issue in
                Link(destination: issue.url) {
                    IssueRow(issue: issue)
                        // 行全体をタップできるように幅を広げる
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                // Link の既定のスタイルは行の文字をすべてアクセントカラーにするため、行の配色を使う
                .buttonStyle(.plain)
            },
            openSettings: { isShowingSettings = true }
        )
        .demoModeBanner()
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
