import Foundation
@testable import OrchestratorKit
import Testing

struct XcbEventTests {
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func decodesJobEvents() {
        let started = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"job_started","id":"j1","path":"/tmp/app-ralph-a","#
            + #""action":"build","platform":"iOS","destination":"platform=iOS Simulator,name=iPhone 17 Pro"}"#)
        let expected = XcbEvent.Started(
            id: "j1", path: "/tmp/app-ralph-a", action: "build", platform: "iOS", destination: "platform=iOS Simulator,name=iPhone 17 Pro"
        )
        #expect(started == XcbEvent(time: time, kind: .jobStarted(expected)))

        let attempt = XcbEvent(
            line: #"{"time":"2027-01-15T08:00:00Z","type":"job_attempt","id":"j1","host":"m4max","slot":"2","attempt":2}"#
        )
        #expect(attempt?.kind == .jobAttempt(id: "j1", host: "m4max", attempt: 2))

        let moved = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"job_moved","id":"j1","from":"m1pro","reason":"disconnected"}"#)
        #expect(moved?.kind == .jobMoved(id: "j1", from: "m1pro", reason: "disconnected"))

        let waiting = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"job_waiting","id":"j1"}"#)
        #expect(waiting?.kind == .jobWaiting(id: "j1", reason: nil))
        let waitingForTest = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"job_waiting","id":"j1","reason":"no_test_host"}"#)
        #expect(waitingForTest?.kind == .jobWaiting(id: "j1", reason: "no_test_host"))
    }

    @Test func decodesFinishedJobs() {
        let finished = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"job_finished","id":"j1","path":"/tmp/app-ralph-b","#
            + #""action":"test","platform":"macOS","host":"local","rc":0,"seconds":95,"attempts":1,"moves":0}"#)
        let expected = XcbEvent.Finished(
            id: "j1",
            path: "/tmp/app-ralph-b",
            action: "test",
            platform: "macOS",
            host: "local",
            exitCode: 0,
            seconds: 95,
            attempts: 1,
            moves: 0
        )
        #expect(finished?.kind == .jobFinished(expected))

        // どこでも動かなかったジョブは host が none。数値の欠け（null）は nil
        let nowhere = XcbEvent(
            line: #"{"time":"2027-01-15T08:00:00Z","type":"job_finished","id":"j2","host":"none","rc":75,"seconds":null}"#
        )
        #expect(nowhere?.kind == .jobFinished(.init(id: "j2", exitCode: 75)))
    }

    @Test func decodesHostEvents() {
        let down = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"host_state","host":"m1pro","state":"down","reason":"接続できない"}"#)
        #expect(down?.kind == .hostState(host: "m1pro", state: "down", reason: "接続できない"))
        // 理由が空なら nil
        let ok = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"host_state","host":"m1pro","state":"ok","reason":""}"#)
        #expect(ok?.kind == .hostState(host: "m1pro", state: "ok", reason: nil))

        let drained = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"host_drained","host":"m4max"}"#)
        #expect(drained?.kind == .hostDrained(host: "m4max"))
        let undrained = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"host_undrained","host":"m4max"}"#)
        #expect(undrained?.kind == .hostUndrained(host: "m4max"))
    }

    @Test func readsNumbersWrittenAsStrings() {
        let attempt = XcbEvent(line: #"{"time":"2027-01-15T08:00:00Z","type":"job_attempt","id":"j1","host":"m4max","attempt":"3"}"#)
        #expect(attempt?.kind == .jobAttempt(id: "j1", host: "m4max", attempt: 3))
    }

    @Test func rejectsLinesMissingRequiredKeys() {
        let lines = [
            "",
            "not json",
            "[1,2]",
            #"{"type":"job_waiting","id":"j1"}"#,
            #"{"time":"yesterday","type":"job_waiting","id":"j1"}"#,
            #"{"time":"2027-01-15T08:00:00Z","id":"j1"}"#,
            #"{"time":"2027-01-15T08:00:00Z","type":"job_unknown","id":"j1"}"#,
            #"{"time":"2027-01-15T08:00:00Z","type":"job_started","id":"j1","action":"build"}"#,
            #"{"time":"2027-01-15T08:00:00Z","type":"job_attempt","id":"j1"}"#,
            #"{"time":"2027-01-15T08:00:00Z","type":"job_moved","id":"j1"}"#,
            #"{"time":"2027-01-15T08:00:00Z","type":"job_finished","id":""}"#,
            #"{"time":"2027-01-15T08:00:00Z","type":"host_state","host":"m1"}"#,
            #"{"time":"2027-01-15T08:00:00Z","type":"host_drained"}"#
        ]
        for line in lines {
            #expect(XcbEvent(line: line) == nil, "\(line)")
        }
    }
}
