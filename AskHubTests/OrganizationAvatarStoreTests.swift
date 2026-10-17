@testable import AskHub
import Foundation
import os
import Testing

/// organization のアバター画像のキャッシュ（通信はスタブに差し替え、ネットワークに依存しない）
@MainActor
struct OrganizationAvatarStoreTests {
    /// 1×1 の PNG
    private static let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )!

    /// 取得した login を数え、決まったデータを返す
    private final class StubFetch: Sendable {
        private let logins = OSAllocatedUnfairLock<[String]>(initialState: [])
        let data: Data?

        init(data: Data?) {
            self.data = data
        }

        var fetched: [String] {
            logins.withLock { $0 }
        }

        func callAsFunction(_ login: String) async -> Data? {
            logins.withLock { $0.append(login) }
            return data
        }
    }

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func isLoaded(_ phase: OrganizationAvatarStore.Phase?) -> Bool {
        if case .loaded = phase {
            return true
        }
        return false
    }

    private func isFailed(_ phase: OrganizationAvatarStore.Phase?) -> Bool {
        if case .failed = phase {
            return true
        }
        return false
    }

    @Test func loadedImageIsCachedAndNotFetchedAgain() async {
        let fetch = StubFetch(data: Self.png)
        let store = OrganizationAvatarStore(fetch: { await fetch($0) })
        await store.load("shilokuma-inc")
        await store.load("shilokuma-inc")
        #expect(isLoaded(store.phase(for: "shilokuma-inc")))
        #expect(fetch.fetched == ["shilokuma-inc"])
    }

    /// login は大文字小文字を区別しないので、同じ画像を使う
    @Test func loginsDifferingOnlyInCaseShareCache() async {
        let fetch = StubFetch(data: Self.png)
        let store = OrganizationAvatarStore(fetch: { await fetch($0) })
        await store.load("Shilokuma-Inc")
        await store.load("shilokuma-inc")
        #expect(isLoaded(store.phase(for: "shilokuma-inc")))
        #expect(fetch.fetched.count == 1)
    }

    /// 同時に読み込みを頼まれても（同じ見出しが何度も作られても）通信は 1 回にする
    @Test func concurrentLoadsFetchOnce() async {
        let fetch = StubFetch(data: Self.png)
        let store = OrganizationAvatarStore(fetch: { await fetch($0) })
        async let first: Void = store.load("shilokuma-inc")
        async let second: Void = store.load("shilokuma-inc")
        _ = await (first, second)
        #expect(fetch.fetched.count == 1)
        #expect(isLoaded(store.phase(for: "shilokuma-inc")))
    }

    @Test func failureIsNotRetriedUntilIntervalPasses() async {
        let fetch = StubFetch(data: nil)
        let clock = Clock()
        let store = OrganizationAvatarStore(fetch: { await fetch($0) }, now: { clock.now }, retryInterval: 300)
        await store.load("shilokuma-inc")
        #expect(isFailed(store.phase(for: "shilokuma-inc")))

        clock.now.addTimeInterval(299)
        await store.load("shilokuma-inc")
        #expect(fetch.fetched.count == 1)

        clock.now.addTimeInterval(2)
        await store.load("shilokuma-inc")
        #expect(fetch.fetched.count == 2)
    }

    /// 画像として読めないデータは失敗として扱う（代わりの表示を出す）
    @Test func undecodableDataFails() async {
        let fetch = StubFetch(data: Data("<html></html>".utf8))
        let store = OrganizationAvatarStore(fetch: { await fetch($0) })
        await store.load("shilokuma-inc")
        #expect(isFailed(store.phase(for: "shilokuma-inc")))
    }

    @Test func offlineStoreNeverLoadsImage() async {
        let store = OrganizationAvatarStore.offline()
        await store.load("shilokuma-inc")
        #expect(isFailed(store.phase(for: "shilokuma-inc")))
    }

    @Test func unloadedLoginHasNoPhase() {
        #expect(OrganizationAvatarStore.offline().phase(for: "shilokuma-inc") == nil)
    }

    /// サンプルデータのモデルは通信しないストアを使う
    @Test func sampleModelUsesOfflineAvatars() async {
        let model = LoopStatusModel.sample()
        await model.avatars.load("shilokuma-inc")
        #expect(isFailed(model.avatars.phase(for: "shilokuma-inc")))
    }
}
