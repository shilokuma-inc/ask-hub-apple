@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

/// 決めた元と画像を返し、呼ばれた回数を数える
final class FakeAppIconSource: AppIconSource {
    struct State {
        var found: [RepositoryFullName: AppIconLocator.Source] = [:]
        var image = Data("png-1".utf8)
        var failure: String?
        var located: [RepositoryFullName] = []
        var rendered: [AppIconLocator.Source] = []
    }

    struct Failure: Error {
        var message: String
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    func locate(_ repo: RepositoryFullName) async throws -> AppIconLocator.Source? {
        try state.withLock { state in
            state.located.append(repo)
            if let failure = state.failure { throw Failure(message: failure) }
            return state.found[repo]
        }
    }

    func render(_ source: AppIconLocator.Source, of repo: RepositoryFullName) async throws -> Data {
        state.withLock { state in
            state.rendered.append(source)
            return state.image
        }
    }
}

struct AppIconSyncTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let other = RepositoryFullName(rawValue: "shilokuma-inc/prime-pick-ios")!
    static let tree = String(repeating: "a", count: 40)
    static let now = Date(timeIntervalSince1970: 1_793_757_600)

    let store = InMemoryStateStore()
    let source = FakeAppIconSource()
    let clock = TestClock(Self.now)

    func sync() -> AppIconSync {
        let clock = clock
        let context = CommanderContext(store: store, mac: MacName(rawValue: "mac-mini")!) { clock.now }
        return AppIconSync(context: context, source: source, log: { _ in }, interval: .seconds(60 * 60))
    }

    func add(_ repo: RepositoryFullName) async throws {
        let file = RepositoryFile(repo: repo, platform: .apple, addedAt: Timestamp(Self.now))
        await store.put(StatePath.repository(repo), data: try StateFileCoder.encode(file))
    }

    func repository(_ repo: RepositoryFullName = Self.repo) async throws -> RepositoryFile {
        let data = try #require(await store.data(at: StatePath.repository(repo)))
        return try StateFileCoder.decode(RepositoryFile.self, from: data)
    }

    @Test func writesImageThenIconAndSkipsUnchangedSource() async throws {
        try await add(Self.repo)
        source.state.withLock { $0.found[Self.repo] = .init(path: "App/AppIcon.icon", tree: Self.tree) }
        let sync = sync()
        #expect(try await sync.refresh(Self.repo))
        let image = try #require(try await store.read(StatePath.appIcon(Self.repo)))
        #expect(image.data == Data("png-1".utf8))
        let icon = try #require(try await repository().icon)
        #expect(icon == .init(source: "App/AppIcon.icon", sourceTree: Self.tree, image: image.sha, updatedAt: Timestamp(Self.now)))

        // 元の tree が同じなら、書き出しも書き込みもしない
        let writes = await store.writeCount
        #expect(try await sync.refresh(Self.repo) == false)
        #expect(await store.writeCount == writes)
        #expect(source.state.withLock { $0.rendered.count } == 1)
    }

    @Test func rewritesWhenSourceChangesAndKeepsIconWhenSourceDisappears() async throws {
        try await add(Self.repo)
        source.state.withLock { $0.found[Self.repo] = .init(path: "App/AppIcon.icon", tree: Self.tree) }
        let sync = sync()
        try await sync.refresh(Self.repo)

        let changed = String(repeating: "b", count: 40)
        source.state.withLock {
            $0.found[Self.repo] = .init(path: "App/AppIcon.icon", tree: changed)
            $0.image = Data("png-2".utf8)
        }
        #expect(try await sync.refresh(Self.repo))
        #expect(await store.data(at: StatePath.appIcon(Self.repo)) == Data("png-2".utf8))
        #expect(try await repository().icon?.sourceTree == changed)
        #expect(try await repository().icon?.image == store.read(StatePath.appIcon(Self.repo))?.sha)

        // 見つからなくなっても、前のアイコンを残す
        source.state.withLock { $0.found[Self.repo] = nil }
        #expect(try await sync.refresh(Self.repo) == false)
        #expect(try await repository().icon?.sourceTree == changed)
    }

    @Test func sameImageFromAnotherTreeOnlyRewritesIcon() async throws {
        try await add(Self.repo)
        source.state.withLock { $0.found[Self.repo] = .init(path: "App/AppIcon.icon", tree: Self.tree) }
        let sync = sync()
        try await sync.refresh(Self.repo)
        let writes = await store.writeCount

        // 中身の同じ画像になる別の tree（icon.json の字下げだけを変えたなど）は、repo.json だけを書く
        source.state.withLock { $0.found[Self.repo] = .init(path: "App/AppIcon.icon", tree: String(repeating: "c", count: 40)) }
        #expect(try await sync.refresh(Self.repo))
        #expect(await store.writeCount == writes + 1)
    }

    @Test func skipsRepositoryWithoutSettings() async throws {
        source.state.withLock { $0.found[Self.repo] = .init(path: "App/AppIcon.icon", tree: Self.tree) }
        #expect(try await sync().refresh(Self.repo) == false)
        #expect(source.state.withLock { $0.located }.isEmpty)
        #expect(await store.data(at: StatePath.appIcon(Self.repo)) == nil)
    }

    @Test func checksEachRepositoryOncePerInterval() async throws {
        try await add(Self.repo)
        try await add(Self.other)
        source.state.withLock {
            $0.found[Self.repo] = .init(path: "App/AppIcon.icon", tree: Self.tree)
            $0.failure = "clone できない"
        }
        let sync = sync()
        await sync.refreshDue()
        // 確かめられなかったリポジトリも、間隔を空けてからやり直す
        #expect(Set(source.state.withLock { $0.located }) == [Self.repo, Self.other])
        source.state.withLock { $0.failure = nil }
        clock.advance(minutes: 30)
        await sync.refreshDue()
        #expect(source.state.withLock { $0.located }.count == 2)

        clock.advance(minutes: 30)
        await sync.refreshDue()
        #expect(source.state.withLock { $0.located }.count == 4)
        #expect(try await repository().icon?.source == "App/AppIcon.icon")
        #expect(try await repository(Self.other).icon == nil)
    }
}
