//
//  AskHub.swift
//  AskHub
//
//  Created by 村石 拓海 on 2024/05/12.
//

import SwiftUI

@main
struct AskHub: App {
    // フォアグラウンド復帰時の自動更新で使うため、一覧のモデルは App が持つ
    @State private var inbox = InboxModel.launchDefault()
    @State private var requests = IdeaRequestModel.launchDefault()
    @State private var mergeQueue = MergeQueueModel.launchDefault()
    @Environment(\.scenePhase)
    private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: inbox, requestModel: requests, mergeModel: mergeQueue)
        }
        .onChange(of: scenePhase) { _, phase in
            // フォアグラウンドに戻ったら取り直す（Discussion #1 の Q7）。直前の取得から間もなければ取り直さない
            switch phase {
            case .active:
                Task { await refreshIfStale() }

            case .background:
                #if os(iOS)
                BackgroundRefresh.schedule()
                #endif

            default:
                break
            }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [inbox, mergeQueue] in
            await BackgroundRefresh.schedule()
            // 時間切れになると取得は打ち切られる。そのときは失敗を表示せず、前回の一覧を残す
            async let inboxRefreshed: Void = inbox.refreshIfStale()
            async let mergeQueueRefreshed: Void = mergeQueue.refreshIfStale()
            _ = await (inboxRefreshed, mergeQueueRefreshed)
        }
        #endif
    }

    private func refreshIfStale() async {
        async let inboxRefreshed: Void = inbox.refreshIfStale()
        async let mergeQueueRefreshed: Void = mergeQueue.refreshIfStale()
        _ = await (inboxRefreshed, mergeQueueRefreshed)
    }
}
