import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// クライアントが通知の宛先（`devices/<device>.json`）を、司令塔が読む形で書くこと
struct PushDestinationWriterTests {
    static let device = KeyID(rawValue: "3GHenKEuXhau_ydZhSS8zpDFx5A1_I5K_ZMmfZsTw1Y")!
    static let now = Date(timeIntervalSince1970: 1_793_757_600)
    static let token = Data([0x00, 0x0f, 0xa1, 0xff] + Array(repeating: 0xb2, count: 28))

    func read(_ store: InMemoryStateStore) async throws -> DeviceFile? {
        try await StateFileStore(store: store).read(DeviceFile.self, at: StatePath.device(Self.device))?.file
    }

    @Test func writesDestinationNamedAfterDeviceKey() async throws {
        let store = InMemoryStateStore()
        let writer = PushDestinationWriter(store: store) { Self.now }
        let push = DeviceFile.Push.apns(deviceToken: Self.token, environment: .development)
        #expect(try await writer.register(device: Self.device, platform: .ios, push: push) == .written)

        let file = try #require(try await read(store))
        #expect(file.device == Self.device)
        #expect(file.platform == .ios)
        // 16 進の小文字で、先頭の 0 も落とさない
        #expect(file.push.token == "000fa1ff" + String(repeating: "b2", count: 28))
        #expect(file.push.service == .apns)
        #expect(file.push.environment == .development)
        #expect(file.updatedAt == Timestamp(Self.now))
        #expect(file.violations.isEmpty)
    }

    @Test func skipsWriteWhenDestinationIsUnchanged() async throws {
        let store = InMemoryStateStore()
        let push = DeviceFile.Push.apns(deviceToken: Self.token, environment: .production)
        try await PushDestinationWriter(store: store) { Self.now }.register(device: Self.device, platform: .macos, push: push)

        let later = PushDestinationWriter(store: store) { Self.now.addingTimeInterval(3_600) }
        #expect(try await later.register(device: Self.device, platform: .macos, push: push) == .unchanged)
        // 書いていないので、書いた時刻は前のまま
        #expect(try await read(store)?.updatedAt == Timestamp(Self.now))
    }

    @Test func rewritesWhenTokenOrEnvironmentChanges() async throws {
        let store = InMemoryStateStore()
        let first = DeviceFile.Push.apns(deviceToken: Self.token, environment: .development)
        try await PushDestinationWriter(store: store) { Self.now }.register(device: Self.device, platform: .ios, push: first)

        let later = Self.now.addingTimeInterval(60)
        let writer = PushDestinationWriter(store: store) { later }
        let renewed = DeviceFile.Push.apns(deviceToken: Data(repeating: 0xc3, count: 32), environment: .development)
        #expect(try await writer.register(device: Self.device, platform: .ios, push: renewed) == .written)
        #expect(try await read(store)?.push.token == String(repeating: "c3", count: 32))
        #expect(try await read(store)?.updatedAt == Timestamp(later))

        // Xcode から入れた版を TestFlight の版に入れ替えると、同じトークンでも APNs の環境が変わる
        let production = DeviceFile.Push.apns(deviceToken: Data(repeating: 0xc3, count: 32), environment: .production)
        #expect(try await writer.register(device: Self.device, platform: .ios, push: production) == .written)
        #expect(try await read(store)?.push.environment == .production)
    }

    @Test func leavesUnreadableFileAlone() async throws {
        let path = StatePath.device(Self.device)
        let future = Data(#"{"v":2,"device":"\#(Self.device)"}"#.utf8)
        let store = InMemoryStateStore(files: [path: future])
        let writer = PushDestinationWriter(store: store) { Self.now }
        let push = DeviceFile.Push.apns(deviceToken: Self.token, environment: .production)

        await #expect(throws: StateFileStore.Failure.self) {
            try await writer.register(device: Self.device, platform: .ios, push: push)
        }
        // 新しい版のアプリが書いたファイルを、古い形で上書きしない
        #expect(await store.data(at: path) == future)
    }
}
