@testable import AskHubKit
import Foundation
import Testing

struct RepositoryStatusReportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func roundTripsMarker() {
        let report = RepositoryStatusReport(usageLimitedUntil: now.addingTimeInterval(3600), checkedAt: now)
        #expect(report.marker.hasPrefix(#"<!-- ask-hub:repository-status {"checkedAt":"#))
        #expect(RepositoryStatusReport.parse(report.marker + "\n## ループの状態\n") == report)

        let idle = RepositoryStatusReport(checkedAt: now)
        #expect(!idle.marker.contains("usageLimitedUntil"))
        #expect(RepositoryStatusReport.parse(idle.marker) == idle)
    }

    @Test func dropsSubsecondsSoReadBackValueMatches() {
        let report = RepositoryStatusReport(
            usageLimitedUntil: now.addingTimeInterval(0.7), checkedAt: now.addingTimeInterval(0.4)
        )
        #expect(report.checkedAt == now)
        #expect(report.usageLimitedUntil == now)
        #expect(RepositoryStatusReport.parse(report.marker) == report)
    }

    @Test func readsMarkerWrittenOutsideSwiftAndIgnoresUnknownKeys() {
        let body = """

          <!-- ask-hub:repository-status {"checkedAt":"2027-01-15T08:00:00Z","future":{"x":1}} -->
        ## ループの状態
        """
        #expect(RepositoryStatusReport.parse(body) == RepositoryStatusReport(checkedAt: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func doesNotMistakeOtherMarkersForEachOther() {
        let loop = LoopStatusReport(state: .running, epic: "epic/x", discussion: 12, checkedAt: now)
        let repository = RepositoryStatusReport(checkedAt: now)
        // 古い形の本文（ループの状態）と新しい形の本文（リポジトリ全体の状態）は、目印の語で見分ける
        #expect(RepositoryStatusReport.parse(loop.issueBody) == nil)
        #expect(LoopStatusReport.parse(repository.marker) == nil)
        #expect(RepositoryStatusReport.parse(#"<!-- ask-hub:repository-statuses {"checkedAt":"2027-01-15T08:00:00Z"} -->"#) == nil)
        // 確認時刻は必須
        #expect(RepositoryStatusReport.parse(#"<!-- ask-hub:repository-status {"usageLimitedUntil":"2027-01-15T08:00:00Z"} -->"#) == nil)
        // 先頭に無い目印は読まない
        #expect(RepositoryStatusReport.parse("人が書いた本文\n" + repository.marker) == nil)
    }

    @Test func writesIssueBodyWithMarkerFirstAndReadableTable() {
        let report = RepositoryStatusReport(usageLimitedUntil: now.addingTimeInterval(3600), checkedAt: now)
        let body = report.issueBody
        #expect(body.hasPrefix(#"<!-- ask-hub:repository-status {"checkedAt":"#))
        #expect(body.contains("| 担当 PC の確認時刻 | "))
        #expect(body.contains("| 上限の解除 | "))
        #expect(body.contains("この Issue のコメントにあります"))
        #expect(RepositoryStatusReport.parse(body) == report)
        // 古いアプリ（ループの状態の目印だけを読む）は、この本文を読まない
        #expect(LoopStatusReport.parse(body) == nil)
        #expect(!RepositoryStatusReport(checkedAt: now).issueBody.contains("上限の解除"))
    }

    @Test func comparesStatusWithoutCheckedTime() {
        let report = RepositoryStatusReport(checkedAt: now)
        #expect(report.hasSameStatus(as: RepositoryStatusReport(checkedAt: now.addingTimeInterval(600))))
        #expect(!report.hasSameStatus(as: RepositoryStatusReport(usageLimitedUntil: now, checkedAt: now)))
    }

    @Test func isAssignedWhileCheckedRecently() {
        let report = RepositoryStatusReport(checkedAt: now)
        #expect(report.isAssigned(now: now.addingTimeInterval(LoopStatusReport.freshness - 1)))
        #expect(!report.isAssigned(now: now.addingTimeInterval(LoopStatusReport.freshness + 1)))
    }
}
