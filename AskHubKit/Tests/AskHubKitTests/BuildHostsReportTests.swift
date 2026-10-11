@testable import AskHubKit
import Foundation
import Testing

struct BuildHostsReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var report: BuildHostsReport {
        BuildHostsReport(
            hosts: [
                .init(name: "macbookpro-m4max", state: .ok, cores: 14, load: 3.25, memoryFreePercent: 41, running: 1, slots: 2),
                .init(name: "macbookpro-m1pro", state: .down, reason: .unreachable),
                .init(name: "local", state: .standby, running: 0, slots: 1)
            ],
            jobs: [
                .init(
                    host: "macbookpro-m4max",
                    repository: "shilokuma-inc/ask-hub-apple",
                    slot: "a",
                    action: "build",
                    platform: "iOS",
                    attempt: 2,
                    startedAt: now.addingTimeInterval(-300)
                )
            ],
            measuredAt: now,
            checkedAt: now
        )
    }

    @Test func roundTripsIssueBody() {
        #expect(BuildHostsReport.parse(report.issueBody) == report)

        let empty = BuildHostsReport(hosts: [], checkedAt: now)
        #expect(BuildHostsReport.parse(empty.issueBody) == empty)
    }

    @Test func roundTripsEveryStateAndReason() {
        for state in BuildHost.State.allCases where state != .unknown {
            for reason in BuildHost.Reason.allCases where reason != .unknown {
                let report = BuildHostsReport(hosts: [.init(name: "m", state: state, reason: reason)], checkedAt: now)
                #expect(BuildHostsReport.parse(report.issueBody) == report)
            }
        }
    }

    @Test func writesMarkerFirstAndReadableTables() {
        let body = report.issueBody
        #expect(body.hasPrefix(#"<!-- ask-hub:build-hosts {"checkedAt":"#))
        #expect(body.contains("| macbookpro-m4max | 使える | 3.25 | 14 | 41% | 1 / 2 |"))
        #expect(body.contains("| macbookpro-m1pro | 切断（接続できない） | - | - | - | - |"))
        #expect(body.contains("| local | 待機 | - | - | - | 0 / 1 |"))
        #expect(body.contains("| macbookpro-m4max | shilokuma-inc/ask-hub-apple | a | build（iOS） | 2 回目 | 2027-01-15T07:55:00Z |"))
        #expect(body.contains("確認時刻: 2027-01-15T08:00:00Z（load・空きメモリ: 2027-01-15T08:00:00Z）"))

        let idle = BuildHostsReport(hosts: [.init(name: "m", state: .drained)], checkedAt: now)
        #expect(!idle.issueBody.contains("| リポジトリ |"))
        #expect(idle.issueBody.contains("| m | 外している | - | - | - | - |"))
    }

    @Test func readsUnknownValuesAndIgnoresUnknownKeys() throws {
        let body = #"<!-- ask-hub:build-hosts {"checkedAt":"2027-01-15T08:00:00Z","extra":1,"#
            + #""hosts":[{"name":"m1","state":"sleeping","reason":"lid","gpu":1}]} -->"#
        let parsed = try #require(BuildHostsReport.parse(body))
        #expect(parsed.checkedAt == now)
        #expect(parsed.hosts == [.init(name: "m1", state: .unknown, reason: .unknown)])
        #expect(parsed.jobs.isEmpty)
        #expect(parsed.measuredAt == nil)
    }

    @Test func rejectsBodiesWithoutMarker() {
        #expect(BuildHostsReport.parse("") == nil)
        #expect(BuildHostsReport.parse("人が書いた本文") == nil)
        #expect(BuildHostsReport.parse("前置き\n" + report.issueBody) == nil)
        #expect(BuildHostsReport.parse(#"<!-- ask-hub:build-hosts-x {"checkedAt":"2027-01-15T08:00:00Z"} -->"#) == nil)
        #expect(BuildHostsReport.parse(#"<!-- ask-hub:loop-status {"checkedAt":"2027-01-15T08:00:00Z","state":"running"} -->"#) == nil)
        // 必須の項目が無い・JSON が崩れている・閉じが無い
        #expect(BuildHostsReport.parse(#"<!-- ask-hub:build-hosts {"hosts":[]} -->"#) == nil)
        let hostWithoutName = #"<!-- ask-hub:build-hosts {"checkedAt":"2027-01-15T08:00:00Z","hosts":[{"state":"ok"}]} -->"#
        #expect(BuildHostsReport.parse(hostWithoutName) == nil)
        #expect(BuildHostsReport.parse("<!-- ask-hub:build-hosts {checked -->") == nil)
        #expect(BuildHostsReport.parse(#"<!-- ask-hub:build-hosts {"checkedAt":"2027-01-15T08:00:00Z"}"#) == nil)
        // 先頭の空白・改行は無視する
        #expect(BuildHostsReport.parse("\n  " + report.issueBody) == report)
    }

    @Test func keepsMarkerIntactWhenValuesContainCommentClose() {
        let report = BuildHostsReport(hosts: [.init(name: "m-->1|x\ny", state: .ok)], checkedAt: now)
        let body = report.issueBody
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        #expect(firstLine.components(separatedBy: "-->").count == 2)
        #expect(BuildHostsReport.parse(body) == report)
        #expect(body.contains(#"| m-->1\|x y | 使える |"#))
    }

    @Test func comparesStatusIgnoringCheckedAtAndMeasurements() {
        var later = report
        later.checkedAt = now.addingTimeInterval(600)
        later.measuredAt = now.addingTimeInterval(600)
        later.hosts[0].load = 5.5
        later.hosts[0].memoryFreePercent = 12
        later.hosts[0].cores = 10
        #expect(report.hasSameStatus(as: later))
        #expect(report != later)

        var disconnected = later
        disconnected.hosts[0].state = .down
        #expect(!report.hasSameStatus(as: disconnected))

        var busier = later
        busier.hosts[0].running = 2
        #expect(!report.hasSameStatus(as: busier))

        var retried = later
        retried.jobs[0].attempt = 3
        #expect(!report.hasSameStatus(as: retried))
    }

    @Test func truncatesFractionalSeconds() {
        var report = BuildHostsReport(hosts: [], measuredAt: now.addingTimeInterval(0.4), checkedAt: now.addingTimeInterval(0.7))
        #expect(report.checkedAt == now)
        #expect(report.measuredAt == now)
        report.checkedAt = now.addingTimeInterval(600.9)
        report.measuredAt = now.addingTimeInterval(300.5)
        report.jobs = [.init(host: "m", repository: "o/r", slot: "b", action: "test", startedAt: now.addingTimeInterval(10.2))]
        #expect(report.checkedAt == now.addingTimeInterval(600))
        #expect(report.measuredAt == now.addingTimeInterval(300))
        #expect(report.jobs[0].startedAt == now.addingTimeInterval(10))
        report.jobs[0].startedAt = now.addingTimeInterval(20.8)
        #expect(report.jobs[0].startedAt == now.addingTimeInterval(20))
        #expect(BuildHostsReport.parse(report.issueBody) == report)
    }

    @Test func assignedOnlyWhileCheckedRecently() {
        #expect(report.isAssigned(now: now.addingTimeInterval(29 * 60)))
        #expect(!report.isAssigned(now: now.addingTimeInterval(31 * 60)))
    }

    @Test func bodyHoldsNoLocalPaths() {
        let body = report.issueBody
        #expect(!body.contains("/Users/"))
        #expect(!body.contains("path"))
        #expect(!body.contains("ralph-a"))
    }
}
