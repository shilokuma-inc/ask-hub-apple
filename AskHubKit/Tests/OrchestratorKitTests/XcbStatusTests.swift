import Foundation
@testable import OrchestratorKit
import Testing

struct XcbStatusTests {
    @Test func decodesStatusOutput() throws {
        let json = #"{"updatedAt":"2027-01-15T08:00:00Z","hosts":["#
            + #"{"name":"m4max","state":"ok","cores":14,"load":3.25,"memoryFreePercent":41,"running":1,"slots":2},"#
            + #"{"name":"m1pro","state":"down","reason":"接続できない","running":0,"slots":1},"#
            + #"{"name":"local","state":"standby","running":0,"slots":1}],"#
            + #""jobs":[{"id":"j1","path":"/src/app-ralph-a","action":"build","platform":"iOS","host":"m4max","#
            + #""attempt":1,"startedAt":"2027-01-15T07:59:00Z"}]}"#
        let status = try #require(XcbStatus.decode(Data(json.utf8)))
        #expect(status.updatedAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(status.hosts == [
            .init(name: "m4max", state: "ok", cores: 14, load: 3.25, memoryFreePercent: 41, running: 1, slots: 2),
            .init(name: "m1pro", state: "down", running: 0, slots: 1),
            .init(name: "local", state: "standby", running: 0, slots: 1)
        ])
    }

    @Test func skipsUnreadableHostsAndKeys() throws {
        let json = #"{"updatedAt":"later","hosts":[{"state":"ok"},{"name":"m4max","state":"ok","load":"high","gpu":1}],"extra":true}"#
        // load が数値でない Mac は読めない Mac として飛ばす。時刻が読めなければ nil
        let status = try #require(XcbStatus.decode(Data(json.utf8)))
        #expect(status.updatedAt == nil)
        #expect(status.hosts.isEmpty)

        #expect(XcbStatus.decode(Data("{}".utf8)) == XcbStatus(hosts: []))
        #expect(XcbStatus.decode(Data("xcb: usage".utf8)) == nil)
    }

    // MARK: - 子プロセス

    private func script(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appending(path: "xcb-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "xcb", directoryHint: .notDirectory)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url.path(percentEncoded: false)
    }

    @Test func runsStatusCommand() async throws {
        // 引数が status --json のときだけ JSON を出す
        let xcb = try script(#"[ "$1 $2" = "status --json" ] || exit 64; echo '{"hosts":[{"name":"local","state":"standby"}]}'"#)
        let status = try await XcbStatusCommand().status(xcbPath: xcb)
        #expect(status.hosts == [.init(name: "local", state: "standby")])
    }

    @Test func reportsFailures() async throws {
        await #expect(throws: XcbStatusError.failed(status: 3)) {
            try await XcbStatusCommand().status(xcbPath: try script("exit 3"))
        }
        await #expect(throws: XcbStatusError.unreadableOutput) {
            try await XcbStatusCommand().status(xcbPath: try script("echo not json"))
        }
        await #expect(throws: XcbStatusError.self) {
            try await XcbStatusCommand().status(xcbPath: "/nonexistent/xcb")
        }
        await #expect(throws: XcbStatusError.timedOut) {
            try await XcbStatusCommand(timeout: .milliseconds(200)).status(xcbPath: try script("exec sleep 30"))
        }
    }
}
