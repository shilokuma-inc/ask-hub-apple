@testable import AskHub
import Foundation
import Testing

/// フォームのドロップの受け口（Discussion #784 のタスク 3）
@MainActor
struct AttachmentDropTargetTests {
    // MARK: - オーバーレイを出す・消す

    @Test func showsOverlayOnlyWhileTargetedAndEnabled() {
        #expect(AttachmentDropOverlayState.state(isTargeted: true, isEnabled: true, hasFiles: true) == .files)
        #expect(AttachmentDropOverlayState.state(isTargeted: true, isEnabled: true, hasFiles: false) == .notFiles)
        // ドラッグが離れた・落とした
        #expect(AttachmentDropOverlayState.state(isTargeted: false, isEnabled: true, hasFiles: true) == nil)
        // 送信中・添付欄が無い（「追加・修正」以外）
        #expect(AttachmentDropOverlayState.state(isTargeted: true, isEnabled: false, hasFiles: true) == nil)
        #expect(AttachmentDropOverlayState.state(isTargeted: true, isEnabled: false, hasFiles: false) == nil)
    }

    @Test func overlayTextsAreJapanese() {
        let files = AttachmentDropOverlay(state: .files)
        #expect(files.title == "ドロップしてファイルを添付")
        #expect(files.message.contains("10 ファイルまで"))
        #expect(AttachmentDropOverlay(state: .notFiles).title == "ファイルではないため添付できません")
    }

    // MARK: - 読み終えたときに足すか

    @Test func addsDroppedItemsOnlyWhileStillEnabled() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "askhub-drop-target-\(UUID().uuidString).txt")
        try Data("内容".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let added = try #require(AttachmentDropAdder.outcome(of: [.fileURL(url)], to: [], isEnabled: true))
        #expect(added.attachments.map(\.name) == [url.lastPathComponent])
        // 読む間に送信が始まった（無効になった）ら、一覧も注意書きも変えない
        #expect(AttachmentDropAdder.outcome(of: [.fileURL(url)], to: [], isEnabled: false) == nil)
        #expect(AttachmentDropAdder.outcome(of: [], to: [], isEnabled: true) == nil)
    }

    // MARK: - NSItemProvider から項目へ

    // ドロップの受け口は macOS だけなので、macOS だけで流す。
    // iOS では `NSURL` の `public.file-url` のデータ表現が URL の文字列ではなく binary plist になり、`.other` になる
    #if os(macOS)
    @Test func fileURLProviderBecomesFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "askhub-drop-target-\(UUID().uuidString).txt")
        try Data("内容".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let item = await AttachmentDropProviders.item(from: NSItemProvider(object: url as NSURL))

        guard case let .fileURL(dropped) = item else {
            Issue.record("ファイルの URL のはず: \(item)")
            return
        }
        #expect(dropped.standardizedFileURL.path == url.standardizedFileURL.path)
    }
    #endif

    @Test func webURLTextAndDataProvidersAreOther() async throws {
        let web = try #require(URL(string: "https://example.com/image.png"))
        let image = NSItemProvider(item: Data([0x89, 0x50, 0x4E, 0x47]) as NSData, typeIdentifier: "public.png")

        let items = await AttachmentDropProviders.items(from: [
            NSItemProvider(object: web as NSURL),
            NSItemProvider(object: "選んだテキスト" as NSString),
            image
        ])

        #expect(items == [.other, .other, .other])
    }

    @Test func noProvidersBecomeNoItems() async {
        #expect(await AttachmentDropProviders.items(from: []).isEmpty)
    }
}
