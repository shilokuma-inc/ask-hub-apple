import SwiftUI

/// 設定の「通知」の節。許可の様子と、状態リポジトリに書いた宛先を出す。断られていれば、通知が届かないことと許可の仕方を出す
struct NotificationSettingsSection: View {
    @Environment(PushRegistration.self) private var push
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Section {
            LabeledContent("許可", value: authorizationLabel)
            LabeledContent("宛先", value: destinationLabel)
            if case .failed(let message) = push.destination {
                Text(message).foregroundStyle(.red)
            }
            if push.authorization == .denied {
                Text("通知が届きません。下のボタンから設定を開き、AskHub の通知を許可してください").foregroundStyle(.red)
                if let url = PushRegistration.settingsURL {
                    Button("通知の設定を開く") { openURL(url) }
                }
            }
        } header: {
            Text("通知")
        } footer: {
            Text(push.authorization == .notDetermined
                ? "この端末の鍵を登録した後に、一度だけ通知の許可を求めます"
                : "回答や承認を待っているもの・止まったジョブ・ジョブを持ったまま戻らない Mac を、常時オンの Mac の司令塔が知らせます")
        }
        // 設定アプリで許可を変えて戻ってきたら読み直す
        .task(id: scenePhase) {
            if scenePhase == .active {
                await push.refreshAuthorization()
            }
        }
    }

    private var authorizationLabel: String {
        switch push.authorization {
        case .unknown: "確かめています…"
        case .notDetermined: "まだ求めていません"
        case .allowed: "許可しています"
        case .denied: "許可していません"
        }
    }

    private var destinationLabel: String {
        switch push.destination {
        case .none: push.authorization == .allowed ? "APNs の登録を待っています" : "まだ書いていません"
        case .writing: "書いています…"
        case .written(.production): "書きました（APNs の本番）"
        case .written(.development): "書きました（APNs の開発用）"
        case .failed: "書けませんでした"
        }
    }
}
