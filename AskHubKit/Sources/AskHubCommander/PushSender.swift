import AskHubProtocol
import Foundation

/// 1 つの端末に送った結果
public enum PushDelivery: Equatable, Sendable {
    case delivered
    /// 宛先が使えない（アプリを消した・宛先が古い・別のアプリの宛先など）。この通知では、もうこの端末に送らない
    case rejected(String)
    /// 送れなかった。しばらくしてから送り直す（APNs の障害・上限・つながらない・鍵や設定の誤りなど）
    case failed(String)
}

/// 通知を送る部品。テストでは、ネットワークに出ずに記録するものに差し替える
public protocol PushSender: Sendable {
    func send(_ notice: PushNotice, to device: DeviceFile) async -> PushDelivery
}
