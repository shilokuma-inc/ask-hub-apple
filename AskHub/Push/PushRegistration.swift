import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 通知の許可と、この端末の宛先（`devices/<device>.json`）の登録（`docs/renewal/operations.md` の「通知」）。
///
/// 状態リポジトリにつながってこの端末の鍵を登録した後に、一度だけ許可を求める。許可されていれば起動のたびに APNs に登録し、
/// 届いたデバイストークンを、この端末の鍵の id の名前で `devices/` に書く（同じ宛先なら書かない）。デモのデータとテストでは何もしない
@Observable
final class PushRegistration {
    enum Authorization: Equatable {
        /// まだ確かめていない
        case unknown
        /// まだ許可を求めていない
        case notDetermined
        case allowed
        case denied
    }

    enum Destination: Equatable {
        case none
        case writing
        case written(APNsEnvironment)
        case failed(String)
    }

    private(set) var authorization: Authorization = .unknown
    private(set) var destination: Destination = .none
    /// 通知から開く先。画面が開いたら消す
    var pendingTarget: PushTarget?

    /// 状態リポジトリを見ているときだけ動く（デモのデータ・UI テスト・撮影・単体テストでは、許可を求めず、宛先も書かない）
    static var isEnabled: Bool {
        isEnabled(source: DataSource.current(), environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(source: DataSource, environment: [String: String]) -> Bool {
        // 単体テストはアプリの中で動くので、同じ Keychain のトークンで本物の状態リポジトリに宛先を書いてしまわないようにする
        source == .stateRepository && environment["XCTestConfigurationFilePath"] == nil
    }

    /// この版の APNs の環境。entitlement の aps-environment と同じ `APS_ENVIRONMENT`（Debug は development、Release は production）を
    /// Info.plist に入れてある
    static let environment = (Bundle.main.object(forInfoDictionaryKey: "AskHubAPNsEnvironment") as? String)
        .flatMap(APNsEnvironment.init(rawValue:))

    /// 許可の様子を確かめ、許可されていれば APNs に登録する。まだ許可を求めていなければ、この端末の鍵が登録されているときだけ求める
    func activate() async {
        guard Self.isEnabled else {
            return
        }
        let center = UNUserNotificationCenter.current()
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            authorization = .notDetermined
            guard await Self.isDeviceKeyRegistered() else {
                return
            }
            // 断られたときも、下で読み直す様子に出る
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshAuthorization()
    }

    /// 許可の様子だけを読み直す（設定アプリで変えて戻ってきたとき）。許可されていれば APNs に登録する
    func refreshAuthorization() async {
        guard Self.isEnabled else {
            return
        }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined:
            authorization = .notDetermined

        case .denied:
            authorization = .denied

        default:
            // 許可・仮の許可（provisional・ephemeral）。APNs は起動のたびに今のトークンを返すので、そのたびに登録する
            authorization = .allowed
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #else
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    /// APNs から届いたデバイストークンを、宛先として書く
    func didRegister(deviceToken: Data) async {
        guard Self.isEnabled else {
            return
        }
        guard let environment = Self.environment else {
            destination = .failed("この版には APNs の環境が入っていません")
            return
        }
        guard let repository = StateConnection.repository() else {
            destination = .failed("状態リポジトリの名前は owner/name の形で入れてください")
            return
        }
        let key: DeviceSigningKey
        do {
            key = try StateConnection.deviceKey()
        } catch {
            destination = .failed("この端末の署名の鍵を用意できませんでした。端末のロックを解除してから開き直してください")
            return
        }
        destination = .writing
        do {
            let writer = PushDestinationWriter(store: StateConnection.makeStore(repository: repository))
            let push = DeviceFile.Push.apns(deviceToken: deviceToken, environment: environment)
            try await writer.register(device: key.keyID, platform: .current, push: push)
            destination = .written(environment)
        } catch {
            destination = .failed(Self.message(for: error))
        }
    }

    func didFailToRegister(_ error: any Error) {
        guard Self.isEnabled else {
            return
        }
        destination = .failed("APNs に登録できませんでした（\(error.localizedDescription)）")
    }

    /// 設定アプリ（Mac はシステム設定）の、このアプリの通知の画面
    static var settingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openNotificationSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
        #endif
    }

    private static func isDeviceKeyRegistered() async -> Bool {
        guard let repository = StateConnection.repository(), let key = try? StateConnection.deviceKey() else {
            return false
        }
        if case .registered = await KeyRegistration.read(from: StateConnection.makeStore(repository: repository), device: key.keyID) {
            return true
        }
        return false
    }

    private static func message(for error: StateFileStore.Failure) -> String {
        switch error {
        case .store(let error):
            StateServiceError.message(for: error)

        case .unreadable:
            "状態リポジトリの通知の宛先を読めません。アプリを新しい版にしてください"

        case .alreadyExists, .notFound, .tooManyConflicts, .invalidFile:
            "通知の宛先を書けませんでした。しばらくしてから開き直してください"
        }
    }
}

extension DevicePlatform {
    /// この端末の種類
    static var current: Self {
        #if os(iOS)
        .ios
        #else
        .macos
        #endif
    }
}
