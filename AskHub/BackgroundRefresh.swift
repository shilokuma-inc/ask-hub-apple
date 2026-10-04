#if os(iOS)
import AskHubKit
import BackgroundTasks
import Foundation

/// iOS の Background App Refresh で一覧を取り直す（Discussion #1 の Q7）。
///
/// 通知は出さない（プッシュ通知は MVP の対象外。Issue #4）。次にアプリを開いたときに新しい一覧を出すためのもの
enum BackgroundRefresh {
    /// Info.plist の `BGTaskSchedulerPermittedIdentifiers`（`$(PRODUCT_BUNDLE_IDENTIFIER).refresh`）と一致させる
    static let identifier = "\(Bundle.main.bundleIdentifier ?? "jp.shilokuma.AskHub").refresh"

    /// 次の実行を予約する。同じ識別子の予約は置き換わる
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(AutoRefresh.backgroundInterval)
        // Simulator や、設定で Background App Refresh がオフのときは失敗する。次にバックグラウンドへ移ったときに予約し直す
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
