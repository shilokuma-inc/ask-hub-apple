import Foundation
@testable import OrchestratorKit
import Testing

struct BuildSlotResolverTests {
    private let resolver = BuildSlotResolver(repositories: [
        RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple"),
        // ディレクトリ名の末尾の -ios は除く（scripts/ralph-setup.sh と同じ）
        RepositoryConfig(owner: "shilokuma-inc", name: "ninjacord", checkoutPath: "/src/ninjacord-ios/")
    ])

    @Test func resolvesLoopSlots() {
        let slotA = BuildSlot(repository: "shilokuma-inc/ask-hub-apple", slot: "a")
        #expect(resolver.slot(forPath: "/src/ask-hub-apple-ralph-a") == slotA)
        #expect(resolver.slot(forPath: "/src/ask-hub-apple-ralph-b/") == BuildSlot(repository: "shilokuma-inc/ask-hub-apple", slot: "b"))
        #expect(resolver.slot(forPath: "/src/ninjacord-ralph-b") == BuildSlot(repository: "shilokuma-inc/ninjacord", slot: "b"))
        // スロットの中のディレクトリで流したビルドもそのスロット
        #expect(resolver.slot(forPath: "/src/ask-hub-apple-ralph-a/AskHubKit") == slotA)
        #expect(resolver.slot(forPath: "/src/x/../ask-hub-apple-ralph-a") == slotA)
    }

    @Test func ignoresBuildsOutsideLoopSlots() {
        let paths = [
            "/src/ask-hub-apple",
            "/src/ask-hub-apple-ralph-ctl",
            "/src/ask-hub-apple-ralph-c",
            "/src/ask-hub-apple-ralph-ab",
            "/src/ask-hub-apple-ralph-a-conflict",
            "/src/ninjacord-ios-ralph-a",
            "/tmp/ask-hub-apple-ralph-a",
            "/src/other-ralph-a",
            ""
        ]
        for path in paths {
            #expect(resolver.slot(forPath: path) == nil, "\(path)")
        }
    }

    @Test func comparesResolvedSymlinks() throws {
        // macOS の一時ディレクトリは /private/var へのシンボリックリンクを含む。xcb は解決したパスを書く
        let parent = FileManager.default.temporaryDirectory.appending(path: "slots-\(UUID().uuidString)", directoryHint: .isDirectory)
        let slot = parent.appending(path: "app-ralph-a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let checkout = parent.appending(path: "app", directoryHint: .isDirectory).path(percentEncoded: false)
        let resolver = BuildSlotResolver(repositories: [RepositoryConfig(owner: "o", name: "app", checkoutPath: checkout)])

        let expected = BuildSlot(repository: "o/app", slot: "a")
        let real = try #require(realpath(slot.path(percentEncoded: false), nil))
        defer { free(real) }
        #expect(resolver.slot(forPath: String(cString: real)) == expected)
        #expect(resolver.slot(forPath: slot.path(percentEncoded: false)) == expected)

        // スロットへのシンボリックリンクで流したビルドも、解決した先で照らす
        let link = parent.appending(path: "link", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: slot)
        #expect(resolver.slot(forPath: link.path(percentEncoded: false)) == expected)
    }

    @Test func resolvesSlotsCreatedAfterResolver() throws {
        // スロットを作る前に作った resolver でも、作った後の xcb の解決したパスと照らせる
        let parent = FileManager.default.temporaryDirectory.appending(path: "slots-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let checkout = parent.appending(path: "app", directoryHint: .isDirectory).path(percentEncoded: false)
        let resolver = BuildSlotResolver(repositories: [RepositoryConfig(owner: "o", name: "app", checkoutPath: checkout)])

        let slot = parent.appending(path: "app-ralph-b", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let real = try #require(realpath(slot.path(percentEncoded: false), nil))
        defer { free(real) }
        #expect(resolver.slot(forPath: String(cString: real)) == BuildSlot(repository: "o/app", slot: "b"))
    }

    @Test func slotWorktreesAreNextToCheckout() {
        let repository = RepositoryConfig(owner: "shilokuma-inc", name: "app", checkoutPath: "/src/ninjacord-ios")
        #expect(repository.slotWorktreePath("a") == "/src/ninjacord-ralph-a")
        #expect(repository.slotWorktreePath("b") == "/src/ninjacord-ralph-b")
        #expect(RepositoryConfig.loopSlots == ["a", "b"])
    }
}
