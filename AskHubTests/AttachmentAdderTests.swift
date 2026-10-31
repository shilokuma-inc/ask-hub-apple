@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// 添付欄のボタンとドロップで共通の「ファイルを足す」処理（Discussion #784 のタスク 1）
@MainActor
struct AttachmentAdderTests {
    /// テストごとに一時ディレクトリを作り、終わったら消す
    private final class Directory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "askhub-adder-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        func file(_ name: String, data: Data = Data("内容".utf8)) throws -> URL {
            let file = url.appending(path: name)
            try data.write(to: file)
            return file
        }

        /// 中身を書かずに大きさだけを持つファイル（上限の確かめで、ディスクとメモリを使わない）
        func sparseFile(_ name: String, size: Int) throws -> URL {
            let file = try file(name, data: Data([0x25, 0x50, 0x44, 0x46]))
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            return file
        }
    }

    private static func existing(_ count: Int) -> [AttachmentFile] {
        (0 ..< count).map { AttachmentFile(name: "既存\($0).txt", type: "text/plain", data: Data("x".utf8)) }
    }

    @Test func addsFilesInSelectedOrderAfterExisting() throws {
        let directory = try Directory()
        let memo = try directory.file("memo.md", data: Data("# メモ".utf8))
        let data = try directory.file("data.json", data: Data("{}".utf8))

        let outcome = AttachmentAdder.add([memo, data], to: Self.existing(1))

        #expect(outcome.attachments.map(\.name) == ["既存0.txt", "memo.md", "data.json"])
        #expect(outcome.attachments[1].data == Data("# メモ".utf8))
        #expect(outcome.notices.isEmpty)
    }

    @Test func rejectsOverflowWithoutReadingAndAddsUpToLimit() throws {
        let directory = try Directory()
        let first = try directory.file("a.txt")
        let second = try directory.file("b.txt")
        // 上限を超える分は読まない（読めないファイルでも「読み込めません」ではなく数の上限で断る）
        let missing = directory.url.appending(path: "missing.png")

        let outcome = AttachmentAdder.add([first, second, missing], to: Self.existing(AttachmentLimits.maxCount - 1))

        #expect(outcome.attachments.count == AttachmentLimits.maxCount)
        #expect(outcome.attachments.last?.name == "a.txt")
        #expect(outcome.notices == [
            "添付は 10 ファイルまでです（b.txt は足していません）",
            "添付は 10 ファイルまでです（missing.png は足していません）"
        ])
    }

    @Test func rejectsEverythingWhenAlreadyFull() throws {
        let directory = try Directory()
        let file = try directory.file("a.txt")
        let current = Self.existing(AttachmentLimits.maxCount)

        let outcome = AttachmentAdder.add([file], to: current)

        #expect(outcome.attachments == current)
        #expect(outcome.notices == ["添付は 10 ファイルまでです（a.txt は足していません）"])
    }

    @Test func explainsUnreadableTooLargeAndEmptyFilesAndAddsTheRest() throws {
        let directory = try Directory()
        let missing = directory.url.appending(path: "missing.png")
        let big = try directory.sparseFile("big.pdf", size: AttachmentLimits.maxFileSize + 1)
        let empty = try directory.file("empty.txt", data: Data())
        let notUTF8 = try directory.file("broken.csv", data: Data([0xFF, 0xFE, 0xFD]))
        let fine = try directory.file("fine.txt")

        let outcome = AttachmentAdder.add([missing, big, empty, notUTF8, fine], to: [])

        #expect(outcome.attachments.map(\.name) == ["fine.txt"])
        // 読めないもの（大きすぎるものを含む）を先に、続けて中身の確認で断ったものを出す（今の添付欄と同じ順）
        #expect(outcome.notices == [
            "missing.png を読み込めませんでした",
            "big.pdf は 10.0 MB を超えるため添付できません",
            "empty.txt は中身が空のため添付できません",
            "broken.csv は UTF-8 のテキストとして読めないため添付できません"
        ])
    }

    @Test func importFailureKeepsAttachmentsAndExplains() {
        struct ImportFailure: Error {}
        let current = Self.existing(2)

        let outcome = AttachmentAdder.add(.failure(ImportFailure()), to: current)

        #expect(outcome.attachments == current)
        #expect(outcome.notices == ["ファイルを読み込めませんでした"])
    }

    @Test func importSuccessAddsLikeURLs() throws {
        let directory = try Directory()
        let file = try directory.file("a.txt")

        let outcome = AttachmentAdder.add(.success([file]), to: [])

        #expect(outcome.attachments.map(\.name) == ["a.txt"])
        #expect(outcome.notices.isEmpty)
    }

    @Test func noticesAreOrderedUnreadableThenRejectedThenOverflow() throws {
        let directory = try Directory()
        let empty = try directory.file("empty.txt", data: Data())
        let missing = directory.url.appending(path: "missing.png")
        let overflow = try directory.file("overflow.txt")

        // 残りは 2 つ。empty.txt と missing.png は読む（読んだ結果で断る）、overflow.txt は読まずに断る
        let outcome = AttachmentAdder.add([empty, missing, overflow], to: Self.existing(AttachmentLimits.maxCount - 2))

        #expect(outcome.attachments.count == AttachmentLimits.maxCount - 2)
        #expect(outcome.notices == [
            "missing.png を読み込めませんでした",
            "empty.txt は中身が空のため添付できません",
            "添付は 10 ファイルまでです（overflow.txt は足していません）"
        ])
    }

    @Test func addingNothingReturnsNoNotices() {
        // 呼び出し側は結果をそのまま代入するので、前の注意書きは消える
        let outcome = AttachmentAdder.add([URL](), to: Self.existing(1))
        #expect(outcome.attachments.count == 1)
        #expect(outcome.notices.isEmpty)
    }
}
