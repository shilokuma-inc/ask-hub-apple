@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

struct BuildReportTests {
    static let token = "ghp_" + String(repeating: "c", count: 36)

    @Test func listsErrorsAndFailedTestsInOrder() {
        let report = BuildReport(
            errors: [BuildIssue(message: "Cannot find 'x' in scope", target: "App", location: "App/Foo.swift:12")],
            failedTests: [
                FailedTest(name: "AppTests/FooTests/testBar()", message: "XCTAssertEqual failed: (\"1\") is not equal to (\"2\")")
            ],
            tests: TestCounts(total: 12, passed: 11, failed: 1, skipped: 0)
        )
        #expect(report.text() == """
        ビルドのエラー（1 件）
        - App/Foo.swift:12 [App] Cannot find 'x' in scope

        落ちたテスト（1 件 / 全 12 件）
        - AppTests/FooTests/testBar(): XCTAssertEqual failed: ("1") is not equal to ("2")
        """)
    }

    @Test func cutsLongListsItemsAndText() {
        let errors = (1...25).map { BuildIssue(message: "error \($0)\n" + String(repeating: "x", count: 500)) }
        let report = BuildReport(errors: errors, log: String(repeating: "y", count: 10_000))
        // 1 件は 1 行に収めて上限で切り、一覧は 20 件まで
        let whole = report.text(limit: 100_000)
        let lines = whole.split(separator: "\n")
        #expect(lines[1].hasPrefix("- error 1 xxx"))
        #expect(lines[1].count == 2 + BuildReport.itemLimit)
        #expect(lines[1].hasSuffix("…（長いので切った）"))
        #expect(lines.contains("- ほか 5 件"))
        #expect(!whole.contains("error 21 "))
        // 全体も上限で切る（先頭のエラーを残す）
        let text = report.text()
        #expect(text.hasPrefix("ビルドのエラー（25 件）\n- error 1 "))
        #expect(text.count == BuildReport.defaultLimit)
        #expect(text.hasSuffix("…（長いので切った）"))
        #expect(report.text(limit: 100).count == 100)
        #expect(report.text(limit: 3).count == 3)
    }

    @Test func redactsTokensEvenInReportsMadeByHand() {
        let report = BuildReport(failedTests: [FailedTest(name: "AppTests/test()", message: "Authorization: Bearer \(Self.token)")])
        #expect(!report.text().contains(Self.token))
        #expect(report.text().contains("<伏せた>"))
    }

    @Test func cleansPathsAndReadsLocations() {
        let cleaner = ReportCleaner(
            sourceDirectory: URL(fileURLWithPath: "/Users/me/Library/AskHub/jobs/01JC/repository/App"),
            home: URL(fileURLWithPath: "/Users/me")
        )
        #expect(cleaner.clean("/Users/me/Library/AskHub/jobs/01JC/repository/App/App/Foo.swift failed") == "App/Foo.swift failed")
        #expect(cleaner.clean("in /Users/me/Library/Developer/Xcode") == "in ~/Library/Developer/Xcode")
        #expect(cleaner.clean("token \(Self.token)") == "token <伏せた>")
        let url = "file:///Users/me/Library/AskHub/jobs/01JC/repository/App/App/Foo.swift"
            + "#EndingColumnNumber=12&EndingLineNumber=10&StartingColumnNumber=5&StartingLineNumber=10"
        #expect(cleaner.location(of: url) == "App/Foo.swift:11")
        #expect(cleaner.location(of: "file:///Users/me/Library/AskHub/jobs/01JC/repository/App/App/Foo.swift") == "App/Foo.swift")
        #expect(cleaner.location(of: nil) == nil)
        #expect(cleaner.location(of: "https://example.com") == nil)
    }

    @Test func prefersErrorLinesInTheLog() {
        let cleaner = ReportCleaner(sourceDirectory: URL(fileURLWithPath: "/work/App"), home: URL(fileURLWithPath: "/Users/me"))
        let output = (1...100).map { "CompileSwift normal arm64 /work/App/File\($0).swift" }.joined(separator: "\n")
            + "\n/work/App/App/Foo.swift:3:5: error: cannot find 'x' in scope\n** BUILD FAILED **\n"
        #expect(cleaner.logExcerpt(of: output) == "App/Foo.swift:3:5: error: cannot find 'x' in scope\n** BUILD FAILED **")
        // エラーらしい行が無ければ末尾
        let plain = (1...100).map { "line \($0)" }.joined(separator: "\n")
        #expect(cleaner.logExcerpt(of: plain)?.hasPrefix("line 71\n") == true)
        #expect(cleaner.logExcerpt(of: "\n\n") == nil)
    }

    @Test func mapsFailureKindsToAttemptFailures() {
        #expect(BuildFailureKind.build.failureClass == .buildFailed)
        #expect(BuildFailureKind.test.failureClass == .testFailed)
        #expect(BuildFailureKind.timeout.failureClass == .timeout)
        #expect(BuildFailureKind.environment.failureClass == .unexpected)
        #expect(BuildFailureKind.unknown.failureClass == .unexpected)

        let report = BuildReport(errors: [BuildIssue(message: String(repeating: "e", count: 5_000))])
        let failure = BuildOutcome(failure: .build, summary: "ビルドが通らない（エラー 1 件）", report: report).attemptFailure
        #expect(failure?.failureClass == .buildFailed)
        #expect(failure?.message == "ビルドが通らない（エラー 1 件）")
        #expect((failure?.logExcerpt?.count ?? 0) <= Redaction.maximumExcerpt)
        #expect(BuildOutcome(failure: nil, summary: "ビルドが通った").attemptFailure == nil)
        #expect(BuildOutcome(failure: .environment, summary: "x").attemptFailure?.logExcerpt == nil)
    }
}
