import AskHubProtocol
import AskHubStateStore
import Foundation

/// この端末の通知の宛先（`devices/<device>.json`）を書く。
///
/// ファイルの名前と `device` は、この端末の公開鍵の id にする。司令塔は、確かめた公開鍵の一覧にある（登録済みで取り消していない）端末の宛先にだけ送る
public struct PushDestinationWriter: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// 新しく書いた・書き直した
        case written
        /// 同じ宛先がもう書いてあるので、書かなかった
        case unchanged
    }

    private let files: StateFileStore
    private let now: @Sendable () -> Date

    public init(store: any StateStore, sleeper: any Sleeper = TaskSleeper(), now: @escaping @Sendable () -> Date = Date.init) {
        files = StateFileStore(store: store, sleeper: sleeper)
        self.now = now
    }

    /// 宛先を書く。同じ宛先がもう書いてあれば書かない（APNs は起動のたびに同じトークンを返すので、そのたびに書き込みを増やさない）。
    /// トークン・環境・端末の種類のどれかが変わっていれば書き直す。今のファイルが読めない（知らない版など）ときは上書きしない
    @discardableResult
    public func register(device: KeyID, platform: DevicePlatform, push: DeviceFile.Push) async throws(StateFileStore.Failure) -> Outcome {
        let path = StatePath.device(device)
        if let current = try await files.read(DeviceFile.self, at: path)?.file,
           current.device == device, current.platform == platform, current.push == push {
            return .unchanged
        }
        let file = DeviceFile(device: device, platform: platform, push: push, updatedAt: Timestamp(now()))
        try await files.replace(file, at: path, message: "[device] \(device)")
        return .written
    }
}

extension DeviceFile.Push {
    /// APNs のデバイストークン（バイト列）から宛先を作る。トークンは 16 進の小文字にする（司令塔は URL のパスにそのまま入れる）
    public static func apns(deviceToken: Data, environment: APNsEnvironment) -> Self {
        Self(service: .apns, token: deviceToken.map { String(format: "%02x", $0) }.joined(), environment: environment)
    }
}
