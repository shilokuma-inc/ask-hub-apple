import SwiftUI
import UserNotifications

/// APNs の登録の結果と、通知を受ける。SwiftUI の App から `@UIApplicationDelegateAdaptor`（Mac は `@NSApplicationDelegateAdaptor`）で使う
final class AppDelegate: NSObject {
    let push = PushRegistration()
}

#if os(iOS)
extension AppDelegate: UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 通知を押して起動したときも受け取れるよう、起動を終える前に受け手を決める
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await push.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        push.didFailToRegister(error)
    }
}
#else
extension AppDelegate: NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 通知を押して起動したときも受け取れるよう、起動を終える前に受け手を決める
        UNUserNotificationCenter.current().delegate = self
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await push.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        push.didFailToRegister(error)
    }
}
#endif

// 完了ハンドラは、呼ばれたその場（UIKit・AppKit が呼ぶ主スレッド）で呼ぶ。async の版にすると、関数を抜けた後の協調スレッドから
// 完了ハンドラが呼ばれ、UIKit が主スレッドかを確かめて止まる（通知を押すとアプリが落ちた。LEARNINGS.md）
extension AppDelegate: UNUserNotificationCenterDelegate {
    /// 開いている間に届いた通知も、バナーで出す
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// 通知を押したら、通知の中身の `askhub` が指す epic・Mac の画面を開く
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let target = PushTarget(userInfo: response.notification.request.content.userInfo) {
            Task { @MainActor in open(target) }
        }
        completionHandler()
    }

    private func open(_ target: PushTarget) {
        push.pendingTarget = target
    }
}
