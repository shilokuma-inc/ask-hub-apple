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

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// 開いている間に届いた通知も、バナーで出す
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// 通知を押したら、通知の中身の `askhub` が指す epic・Mac の画面を開く
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let target = PushTarget(userInfo: response.notification.request.content.userInfo) else {
            return
        }
        await open(target)
    }

    private func open(_ target: PushTarget) {
        push.pendingTarget = target
    }
}
