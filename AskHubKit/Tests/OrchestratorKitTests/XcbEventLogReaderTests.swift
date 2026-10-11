import Foundation
@testable import OrchestratorKit
import Testing

struct XcbEventLogReaderTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "xcb-events-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var currentURL: URL {
        directory.appending(path: XcbEventLogReader.fileName)
    }

    private var rotatedURL: URL {
        directory.appending(path: XcbEventLogReader.rotatedFileName)
    }

    private func line(_ type: String, _ id: String, time: String = "2026-10-11T00:00:00Z") -> String {
        #"{"time":"\#(time)","type":"\#(type)","id":"\#(id)"}"#
    }

    private func append(_ text: String, to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    /// xcb と同じく `events.jsonl` を `.1` に移す（`mv -f`）
    private func rotate() throws {
        if FileManager.default.fileExists(atPath: rotatedURL.path) {
            try FileManager.default.removeItem(at: rotatedURL)
        }
        try FileManager.default.moveItem(at: currentURL, to: rotatedURL)
    }

    private func ids(_ events: [XcbEvent]) -> [String] {
        events.compactMap { event in
            if case let .jobWaiting(id, _) = event.kind { id } else { nil }
        }
    }

    @Test func readsNothingWhenLogIsMissing() {
        var reader = XcbEventLogReader(directory: directory)
        #expect(reader.readNewEvents().isEmpty)
        #expect(reader.position == nil)
    }

    @Test func readsOnlyNewLinesSinceLastRead() throws {
        try append(line("job_waiting", "1") + "\n" + line("job_waiting", "2") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        #expect(ids(reader.readNewEvents()) == ["1", "2"])
        #expect(reader.readNewEvents().isEmpty)

        try append(line("job_waiting", "3") + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["3"])
    }

    @Test func leavesPartialLastLineForNextRead() throws {
        let third = line("job_waiting", "3")
        try append(line("job_waiting", "1") + "\n" + third.prefix(20), to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        #expect(ids(reader.readNewEvents()) == ["1"])
        #expect(reader.readNewEvents().isEmpty)

        try append(third.dropFirst(20) + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["3"])
    }

    @Test func readsRestOfRotatedLogThenNewLog() throws {
        try append(line("job_waiting", "1") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        #expect(ids(reader.readNewEvents()) == ["1"])

        // 前回の後に 2 が書かれてから回り、新しいファイルに 3 が書かれた
        try append(line("job_waiting", "2") + "\n", to: currentURL)
        try rotate()
        try append(line("job_waiting", "3") + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["2", "3"])
        #expect(reader.readNewEvents().isEmpty)

        try append(line("job_waiting", "4") + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["4"])
    }

    @Test func readsRotatedLogBeforeNewLogIsCreated() throws {
        try append(line("job_waiting", "1") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        #expect(ids(reader.readNewEvents()) == ["1"])

        try append(line("job_waiting", "2") + "\n", to: currentURL)
        try rotate()
        #expect(ids(reader.readNewEvents()) == ["2"])
        // 新しいファイルができたら頭から読み、`.1` は読み直さない
        try append(line("job_waiting", "3") + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["3"])
    }

    @Test func keepsPositionWhenRotatedLogCannotBeRead() throws {
        try append(line("job_waiting", "1") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        #expect(ids(reader.readNewEvents()) == ["1"])

        try append(line("job_waiting", "2") + "\n", to: currentURL)
        try rotate()
        try append(line("job_waiting", "3") + "\n", to: currentURL)
        // `.1` が読めないあいだは `events.jsonl` に進まない
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rotatedURL.path(percentEncoded: false))
        let position = reader.position
        #expect(reader.readNewEvents().isEmpty)
        #expect(reader.position == position)

        // 読めるようになったら `.1` の残りから読む
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rotatedURL.path(percentEncoded: false))
        #expect(ids(reader.readNewEvents()) == ["2", "3"])
    }

    @Test func movesOnFromFullyReadRotatedLog() throws {
        try append(line("job_waiting", "1") + "\n", to: currentURL)
        try rotate()
        var reader = XcbEventLogReader(directory: directory)
        #expect(ids(reader.readNewEvents()) == ["1"])
        // `.1` を読み終えていても、新しい `events.jsonl` に進む
        try append(line("job_waiting", "2") + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["2"])
        #expect(reader.readNewEvents().isEmpty)
    }

    @Test func readsRotatedAndCurrentLogsFromStartOnFirstRead() throws {
        try append(line("job_waiting", "1") + "\n" + line("job_waiting", "2"), to: rotatedURL)
        try append(line("job_waiting", "3") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        // 回したファイルの改行の無い最後の行も読む
        #expect(ids(reader.readNewEvents()) == ["1", "2", "3"])
    }

    @Test func readsBothLogsFromStartWhenLastFileIsGone() throws {
        try append(line("job_waiting", "1") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        _ = reader.readNewEvents()

        // 読まないうちに 2 回回った（前回のファイルはもう無い）
        try rotate()
        try append(line("job_waiting", "2") + "\n", to: currentURL)
        try rotate()
        try append(line("job_waiting", "3") + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["2", "3"])
    }

    @Test func readsFromStartWhenLogWasTruncated() throws {
        try append(line("job_waiting", "1") + "\n" + line("job_waiting", "2") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        _ = reader.readNewEvents()

        // 同じファイルが短くなった（手で空にした）
        let handle = try FileHandle(forWritingTo: currentURL)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try append(line("job_waiting", "3") + "\n", to: currentURL)
        #expect(ids(reader.readNewEvents()) == ["3"])
    }

    @Test func skipsBrokenAndUnknownLines() throws {
        let lines = [
            line("job_waiting", "1"),
            "{broken",
            "",
            #"{"time":"2026-10-11T00:00:00Z","type":"job_teleported","id":"x"}"#,
            #"{"type":"job_waiting","id":"no-time"}"#,
            #"{"time":"2026-10-11T00:00:00Z","type":"job_waiting"}"#,
            "\u{FF}\u{FE}",
            line("job_waiting", "2")
        ]
        try append(lines.joined(separator: "\n") + "\n", to: currentURL)
        var reader = XcbEventLogReader(directory: directory)
        #expect(ids(reader.readNewEvents()) == ["1", "2"])
    }
}
