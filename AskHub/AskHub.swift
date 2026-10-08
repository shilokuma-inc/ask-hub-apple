//
//  AskHub.swift
//  AskHub
//
//  Created by 村石 拓海 on 2024/05/12.
//

import AskHubKit
import SwiftUI

@main
struct AskHub: App {
    // フォアグラウンド復帰時と定期の自動更新で使うため、一覧のモデルは App が持つ
    @State private var inbox = InboxModel.launchDefault()
    @State private var requests = IdeaRequestModel.launchDefault()
    @State private var mergeQueue = MergeQueueModel.launchDefault()
    @State private var loopStatus = LoopStatusModel.launchDefault()
    @State private var isDemoMode = DemoMode.isEnabled
    @Environment(\.scenePhase)
    private var scenePhase

    init() {
        #if DEBUG
        // UI テスト（サンプルデータの起動引数）は、前回の起動で設定画面から切り替えた値に左右されないよう既定値から始める
        if ProcessInfo.processInfo.arguments.contains(InboxModel.sampleLaunchArgument) {
            LoopStartPreference.reset()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: inbox, requestModel: requests, mergeModel: mergeQueue, loopModel: loopStatus)
                .environment(\.isDemoMode, isDemoMode)
                .environment(\.setDemoMode) { setDemoMode($0) }
                // アプリを開いているあいだ（バックグラウンド以外）は、全タブの一覧を定期的に取り直す（Issue #299）。
                // バックグラウンドに移ると取り消されて止まり、戻ると数え直す（戻った直後の取り直しは onChange が行う）
                .task(id: scenePhase == .background) {
                    guard scenePhase != .background else {
                        return
                    }
                    await AutoRefresh.repeating(every: AutoRefresh.foregroundInterval) {
                        await refreshPeriodically()
                    }
                }
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

    /// デモモードを切り替え、一覧のモデルをサンプルデータ（または GitHub）のものに差し替える
    private func setDemoMode(_ enabled: Bool) {
        DemoMode.isEnabled = enabled
        isDemoMode = enabled
        inbox = enabled ? .sample() : InboxModel()
        requests = enabled ? .sample() : IdeaRequestModel()
        mergeQueue = enabled ? .sample() : MergeQueueModel()
        loopStatus = enabled ? .sample() : LoopStatusModel()
    }

    /// 定期の取り直し。全タブの一覧と依頼先のリポジトリを取り直す。直前の取得から間もない一覧（手で更新した直後など）は飛ばす
    private func refreshPeriodically() async {
        async let listsRefreshed: Void = refreshIfStale()
        async let repositoriesReloaded: Void = requests.reloadRepositoriesIfStale()
        _ = await (listsRefreshed, repositoriesReloaded)
    }

    private func refreshIfStale() async {
        async let inboxRefreshed: Void = inbox.refreshIfStale()
        async let mergeQueueRefreshed: Void = mergeQueue.refreshIfStale()
        async let loopStatusRefreshed: Void = loopStatus.refreshIfStale()
        _ = await (inboxRefreshed, mergeQueueRefreshed, loopStatusRefreshed)
    }
}
