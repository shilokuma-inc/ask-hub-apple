import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

struct OrchestratorBuildHostsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let repository = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
    private let events: URL

    init() throws {
        events = FileManager.default.temporaryDirectory.appending(path: "xcb-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    }

    private func makeOrchestrator(
        github: FakeGitHub,
        xcb: FakeXcbStatus,
        issueRepository: String? = "shilokuma-inc/ask-hub-apple",
        now: @escaping @Sendable () -> Date
    ) throws -> Orchestrator {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [repository],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}"]),
            buildHosts: BuildHostsConfig(
                xcbPath: "/opt/xcb", eventsDirectory: events.path(percentEncoded: false), issueRepository: issueRepository
            )
        )
        return Orchestrator(
            config: config, github: github, inbox: FakeInbox(), runtime: FakeRuntime(), log: { _ in }, now: now, xcbStatus: xcb
        )
    }

    private func append(_ lines: [String]) throws {
        let url = events.appending(path: XcbEventLogReader.fileName)
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
    }

    private func status(load: Double) -> XcbStatus {
        XcbStatus(hosts: [
            .init(name: "macbookpro-m4max", state: "ok", cores: 14, load: load, memoryFreePercent: 41, running: 0, slots: 2),
            .init(name: "macbookpro-m1pro", state: "down", running: 0, slots: 1),
            .init(name: "local", state: "standby", running: 0, slots: 1)
        ])
    }

    private func report(_ github: FakeGitHub) -> BuildHostsReport? {
        github.buildHostsIssuesByNumber[201].flatMap { BuildHostsReport.parse($0.body) }
    }

    @Test func createsIssueAndRewritesOnChangeOrInterval() async throws {
        try append([
            #"{"time":"2027-01-15T07:59:00Z","type":"job_started","id":"j1","path":"/src/ask-hub-apple-ralph-a","#
                + #""action":"build","platform":"iOS"}"#,
            #"{"time":"2027-01-15T07:59:01Z","type":"job_attempt","id":"j1","host":"macbookpro-m4max","slot":"1","attempt":1}"#
        ])
        let github = FakeGitHub([.success([])])
        let xcb = FakeXcbStatus([status(load: 3.25), status(load: 5.5)])
        let clock = OSAllocatedUnfairLock(initialState: start)
        let orchestrator = try makeOrchestrator(github: github, xcb: xcb) { clock.withLock { $0 } }

        try await orchestrator.pollOnce()
        #expect(github.createdBuildHostsIssues == ["shilokuma-inc/ask-hub-apple#201"])
        #expect(xcb.calls == 1)
        let first = try #require(report(github))
        // xcb status --json の並びと値に、イベントで分かる実行中の本数を重ねる
        #expect(first.hosts == [
            BuildHost(name: "macbookpro-m4max", state: .ok, cores: 14, load: 3.25, memoryFreePercent: 41, running: 1, slots: 2),
            BuildHost(name: "macbookpro-m1pro", state: .down, running: 0, slots: 1),
            BuildHost(name: "local", state: .standby, running: 0, slots: 1)
        ])
        #expect(first.jobs.map(\.repository) == ["shilokuma-inc/ask-hub-apple"])
        #expect(first.measuredAt == start)
        // 本文にローカルパスを書かない
        #expect(github.buildHostsIssuesByNumber[201]?.body.contains("/src/") == false)

        // 変化が無ければ書かず、xcb も呼ばない
        clock.withLock { $0 = start.addingTimeInterval(60) }
        try await orchestrator.pollOnce()
        #expect(github.updatedBuildHostsIssues.isEmpty)
        #expect(xcb.calls == 1)

        // イベントで分かる変化（終わった）は、間隔を待たずに書く。load は前の値のまま
        try append([
            #"{"time":"2027-01-15T08:01:30Z","type":"job_finished","id":"j1","path":"/src/ask-hub-apple-ralph-a","action":"build","#
                + #""host":"macbookpro-m4max","rc":0,"seconds":150,"attempts":1,"moves":0}"#
        ])
        clock.withLock { $0 = start.addingTimeInterval(120) }
        try await orchestrator.pollOnce()
        #expect(github.updatedBuildHostsIssues.count == 1)
        #expect(report(github)?.jobs.isEmpty == true)
        #expect(report(github)?.hosts.first?.running == 0)
        #expect(report(github)?.hosts.first?.load == 3.25)
        #expect(xcb.calls == 1)

        // 間隔を過ぎたら xcb status --json を取り直し、load を新しくして書き直す
        clock.withLock { $0 = start.addingTimeInterval(120 + BuildHostsReport.updateInterval) }
        try await orchestrator.pollOnce()
        #expect(xcb.calls == 2)
        #expect(github.updatedBuildHostsIssues.count == 2)
        #expect(report(github)?.hosts.first?.load == 5.5)
    }

    @Test func writesEventStateEvenIfStatusFails() async throws {
        try append([
            #"{"time":"2027-01-15T07:59:00Z","type":"host_state","host":"macbookpro-m1pro","state":"down","reason":"接続できない"}"#
        ])
        let github = FakeGitHub([.success([])])
        let xcb = FakeXcbStatus([])
        let orchestrator = try makeOrchestrator(github: github, xcb: xcb) { start }

        try await orchestrator.pollOnce()
        let written = try #require(report(github))
        #expect(written.hosts == [BuildHost(name: "macbookpro-m1pro", state: .down, reason: .unreachable, running: 0)])
        #expect(written.measuredAt == nil)
        // xcb の理由の文（パスを含みうる）は書かない
        #expect(github.buildHostsIssuesByNumber[201]?.body.contains("接続できない（") == false)
    }

    @Test func reusesTrustedIssueAndSkipsWhenRepositoryIsNotAssigned() async throws {
        let github = FakeGitHub([.success([])])
        // 信用しない author の Issue は使わず、信用する author の閉じた Issue を開き直して使う
        github.setBuildHostsIssues([
            LoopStatusIssueRecord(number: 7, author: "someone", isOpen: true, updatedAt: start, body: "spam"),
            LoopStatusIssueRecord(number: 5, author: "mrs1669", isOpen: false, updatedAt: start.addingTimeInterval(-3600), body: "")
        ])
        try await makeOrchestrator(github: github, xcb: FakeXcbStatus([status(load: 1)])) { start }.pollOnce()
        #expect(github.createdBuildHostsIssues.isEmpty)
        #expect(github.updatedBuildHostsIssues == ["shilokuma-inc/ask-hub-apple#5"])

        // 置き場所が担当リポジトリでなければ書かず、xcb も呼ばない
        let other = FakeGitHub([.success([])])
        let xcb = FakeXcbStatus([status(load: 1)])
        try await makeOrchestrator(github: other, xcb: xcb, issueRepository: "shilokuma-inc/other") { start }.pollOnce()
        #expect(other.createdBuildHostsIssues.isEmpty)
        #expect(xcb.calls == 0)
    }
}
