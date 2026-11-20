@testable import AskHub
import AskHubProtocol
import Foundation
import Testing

/// Siri・ショートカットの依頼の文を、要約と依頼の内容に分ける
struct ShortcutRequestTextTests {
    @Test
    func oneLineIsSummaryOnly() throws {
        let request = try #require(ShortcutRequestText("  週ごとのまとめ通知を足したい \n"))

        #expect(request.summary == "週ごとのまとめ通知を足したい")
        #expect(request.body.isEmpty)
    }

    @Test(arguments: ["週ごとのまとめ通知\n日曜の夜に 1 回だけ届けたい\n\n件数も出したい", "週ごとのまとめ通知\r\n日曜の夜に 1 回だけ届けたい\r\n\r\n件数も出したい"])
    func firstLineIsSummaryAndRestIsBody(text: String) throws {
        let request = try #require(ShortcutRequestText(text))

        #expect(request.summary == "週ごとのまとめ通知")
        #expect(request.body == "日曜の夜に 1 回だけ届けたい\n\n件数も出したい")
    }

    @Test(arguments: ["", "   ", " \n \r\n "])
    func blankTextIsNil(text: String) {
        #expect(ShortcutRequestText(text) == nil)
    }

    /// 1 行目が長すぎれば要約を切り詰め、言ったことを落とさないよう全文を内容に入れる
    @Test
    func longFirstLineIsTruncatedAndKeptInBody() throws {
        let firstLine = String(repeating: "あ", count: RequestIntent.maximumTitleLength + 50)
        let text = "\(firstLine)\n続き"
        let request = try #require(ShortcutRequestText(text))

        #expect(request.summary.unicodeScalars.count == RequestIntent.maximumTitleLength)
        #expect(request.summary.hasSuffix("…"))
        #expect(request.summary.hasPrefix("あああ"))
        #expect(request.body == text)
    }

    /// 要約の長さは、司令塔と同じく Unicode のスカラーで数える。絵文字の途中では切らない
    @Test
    func truncationCountsScalarsAndKeepsCharactersWhole() throws {
        // 国旗は 2 つのスカラーで 1 文字
        let firstLine = String(repeating: "🇯🇵", count: RequestIntent.maximumTitleLength)
        let request = try #require(ShortcutRequestText(firstLine))

        #expect(request.summary.unicodeScalars.count <= RequestIntent.maximumTitleLength)
        #expect(request.summary.dropLast().allSatisfy { $0 == "🇯🇵" })
        #expect(request.body == firstLine)
    }

    @Test
    func firstLineAtLimitIsNotTruncated() throws {
        let firstLine = String(repeating: "a", count: RequestIntent.maximumTitleLength)
        let request = try #require(ShortcutRequestText(firstLine))

        #expect(request.summary == firstLine)
        #expect(request.body.isEmpty)
    }
}
