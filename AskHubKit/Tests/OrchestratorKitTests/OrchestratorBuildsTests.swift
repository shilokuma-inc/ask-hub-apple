import AskHubKit
import Foundation
@testable import OrchestratorKit
import os
import Testing

struct OrchestratorBuildsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let repository = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
    private let events: URL

    init() throws {
        events = FileManager.default.temporaryDirectory.appending(path: "xcb-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    }

    private func makeOrchestrator(
        github: FakeGitHub, buildHosts: BuildHostsConfig?, now: @escaping @Sendable () -> Date
    ) throws -> Orchestrator {
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [repository],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop", "{repository}"]),
            buildHosts: buildHosts
        )
        return Orchestrator(config: config, github: github, inbox: FakeInbox(), runtime: FakeRuntime(), log: { _ in }, now: now)
    }

    private var settings: BuildHostsConfig {
        BuildHostsConfig(xcbPath: "/opt/xcb", eventsDirectory: events.path(percentEncoded: false))
    }

    /// xcb と同じく 1 行ずつ追記する
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

    private func report(_ github: FakeGitHub) -> LoopStatusReport? {
        github.loopStatusIssuesByNumber[101].flatMap { LoopStatusReport.parse($0.body) }
    }

    @Test func writesBuildsOfLoopSlotsAndRewritesWhenTheyChange() async throws {
        try append([
            #"{"time":"2027-01-15T07:59:00Z","type":"job_started","id":"j1","path":"/src/ask-hub-apple-ralph-a","#
                + #""action":"build","platform":"iOS"}"#,
            #"{"time":"2027-01-15T07:59:01Z","type":"job_attempt","id":"j1","host":"macbookpro-m4max","slot":"1","attempt":1}"#,
            // スロット以外（メインの checkout）のビルドは書かない
            #"{"time":"2027-01-15T07:59:02Z","type":"job_started","id":"j2","path":"/src/ask-hub-apple","#
                + #""action":"test","platform":"macOS"}"#
        ])
        let github = FakeGitHub([.success([])])
        let clock = OSAllocatedUnfairLock(initialState: start)
        let orchestrator = try makeOrchestrator(github: github, buildHosts: settings) { clock.withLock { $0 } }

        try await orchestrator.pollOnce()
        let running = try #require(report(github)?.builds?.running)
        let expected = LoopStatusBuild(
            slot: "a", action: "build", platform: "iOS", host: "macbookpro-m4max", attempt: 1, startedAt: start.addingTimeInterval(-60)
        )
        #expect(running == [expected])
        // 本文にローカルパスを書かない
        #expect(github.loopStatusIssuesByNumber[101]?.body.contains("/src/") == false)

        // イベントで分かる変化（移動）があれば、間隔を待たずに書き換える
        clock.withLock { $0 = start.addingTimeInterval(60) }
        try append([
            #"{"time":"2027-01-15T08:00:30Z","type":"job_moved","id":"j1","from":"macbookpro-m4max","reason":"disconnected"}"#,
            #"{"time":"2027-01-15T08:00:31Z","type":"job_attempt","id":"j1","host":"macbookpro-m1pro","slot":"1","attempt":2}"#
        ])
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues.count == 1)
        #expect(report(github)?.builds?.running.first?.host == "macbookpro-m1pro")
        #expect(report(github)?.builds?.running.first?.moves.first?.from == "macbookpro-m4max")

        // 変化が無ければ書かない
        clock.withLock { $0 = start.addingTimeInterval(120) }
        try await orchestrator.pollOnce()
        #expect(github.updatedLoopStatusIssues.count == 1)

        // 終われば直近のビルドと 24 時間の移動に移る
        try append([
            #"{"time":"2027-01-15T08:02:00Z","type":"job_finished","id":"j1","path":"/src/ask-hub-apple-ralph-a","action":"build","#
                + #""platform":"iOS","host":"macbookpro-m1pro","rc":0,"seconds":180,"attempts":2,"moves":1}"#
        ])
        try await orchestrator.pollOnce()
        let builds = try #require(report(github)?.builds)
        #expect(builds.running.isEmpty)
        #expect(builds.latest.map(\.succeeded) == [true])
        #expect(builds.moved.count == 1)
    }

    @Test func omitsBuildsWithoutSettingsOrBuilds() async throws {
        try append([
            #"{"time":"2027-01-15T07:59:00Z","type":"job_started","id":"j1","path":"/src/ask-hub-apple-ralph-a","action":"build"}"#
        ])
        // buildHosts が無ければイベントログを読まない
        let off = FakeGitHub([.success([])])
        try await makeOrchestrator(github: off, buildHosts: nil) { start }.pollOnce()
        #expect(report(off)?.builds == nil)
        #expect(report(off) != nil)

        // ビルドが 1 つも無ければキーを書かない
        let empty = FakeGitHub([.success([])])
        let elsewhere = BuildHostsConfig(xcbPath: "/opt/xcb", eventsDirectory: events.appending(path: "none").path(percentEncoded: false))
        try await makeOrchestrator(github: empty, buildHosts: elsewhere) { start }.pollOnce()
        #expect(report(empty)?.builds == nil)
        #expect(empty.loopStatusIssuesByNumber[101]?.body.contains("builds") == false)
    }
}
