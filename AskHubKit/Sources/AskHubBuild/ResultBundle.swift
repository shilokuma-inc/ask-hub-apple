import AskHubCommands
import Foundation

/// 結果のバンドル（`.xcresult`）から読んだもの。`xcrun xcresulttool get build-results` と
/// `get test-results summary`（Xcode 16 からの形。JSON Schema の版 0.4.0 で確かめた）の、使う欄だけ
struct ResultBundleContents: Equatable {
    struct BuildResults: Decodable, Equatable {
        var errors: [XcresultIssue]?
    }

    struct TestSummary: Decodable, Equatable {
        /// `Passed`・`Failed`・`Skipped`・`Expected Failure`・`unknown`
        var result: String?
        var totalTestCount: Int?
        var passedTests: Int?
        var failedTests: Int?
        var skippedTests: Int?
        var testFailures: [XcresultTestFailure]?
    }

    var build: BuildResults?
    var tests: TestSummary?
}

/// `build-results` の `errors` の 1 件
struct XcresultIssue: Decodable, Equatable {
    var message: String
    var targetName: String?
    var sourceURL: String?
}

/// `test-results summary` の `testFailures` の 1 件
struct XcresultTestFailure: Decodable, Equatable {
    var testName: String?
    var targetName: String?
    var failureText: String?
    var testIdentifierString: String?
}

/// `xcrun xcresulttool` で結果のバンドルを読む。読めなければ、その部分を nil にする
struct ResultBundleReader {
    var tools: BuildTools
    var runner: any CommandRunning
    var timeout: Duration

    func read(_ bundle: URL, tests: Bool) async -> ResultBundleContents {
        guard FileManager.default.fileExists(atPath: bundle.path) else { return ResultBundleContents() }
        var contents = ResultBundleContents()
        contents.build = await decode(ResultBundleContents.BuildResults.self, ["get", "build-results"], bundle: bundle)
        if tests {
            contents.tests = await decode(ResultBundleContents.TestSummary.self, ["get", "test-results", "summary"], bundle: bundle)
        }
        return contents
    }

    private func decode<T: Decodable>(_ type: T.Type, _ subcommand: [String], bundle: URL) async -> T? {
        let arguments = ["xcresulttool"] + subcommand + ["--path", bundle.path, "--compact"]
        let command = tools.command(arguments, in: bundle.deletingLastPathComponent(), timeout: timeout)
        guard let result = try? await runner.run(command), result.succeeded else { return nil }
        return try? JSONDecoder().decode(type, from: result.standardOutput)
    }
}

/// 結果の文を、Claude に渡せる形に整える。写しのパスは相対パスに、ホームフォルダは `~` にし、トークンらしい文字列を伏せる
struct ReportCleaner {
    var sourceDirectory: URL
    var home: URL

    func clean(_ text: String) -> String {
        var text = text
        let source = sourceDirectory.standardizedFileURL.path
        if source.count > 1 {
            text = text.replacingOccurrences(of: source + "/", with: "")
            text = text.replacingOccurrences(of: source, with: ".")
        }
        let home = home.standardizedFileURL.path
        if home.count > 1 {
            text = text.replacingOccurrences(of: home, with: "~")
        }
        return Redaction.redact(text, secrets: [])
    }

    /// `file:///…/Foo.swift#…&StartingLineNumber=11&…` を `Foo.swift:12` の形にする（結果のバンドルの行は 0 から数える）
    func location(of sourceURL: String?) -> String? {
        guard let sourceURL, let url = URL(string: sourceURL), url.isFileURL else { return nil }
        let path = clean(url.path)
        let line = (url.fragment ?? "").split(separator: "&").lazy.compactMap { item -> Int? in
            guard item.hasPrefix("StartingLineNumber=") else { return nil }
            return Int(item.dropFirst("StartingLineNumber=".count))
        }.first
        return line.map { "\(path):\($0 + 1)" } ?? path
    }

    /// 結果のバンドルの中身から要約を作る（出力の抜粋は入れない）
    func report(from contents: ResultBundleContents) -> BuildReport {
        // 「ビルドが失敗したのでテストを取り消した」は理由ではないので除く
        let issues = (contents.build?.errors ?? []).filter { !$0.message.hasPrefix("Testing cancelled because the build failed") }
        let errors = issues.map { issue in
            BuildIssue(message: clean(issue.message), target: issue.targetName, location: location(of: issue.sourceURL))
        }
        let failures = (contents.tests?.testFailures ?? []).map { failure in
            let test = failure.testIdentifierString ?? failure.testName ?? "（名前の無いテスト）"
            let name = [failure.targetName, test].compactMap { $0 }.joined(separator: "/")
            return FailedTest(name: name, message: clean(failure.failureText ?? ""))
        }
        let counts = contents.tests.flatMap { summary in
            summary.totalTestCount.map { total in
                TestCounts(
                    total: total, passed: summary.passedTests ?? 0, failed: summary.failedTests ?? 0, skipped: summary.skippedTests ?? 0
                )
            }
        }
        return BuildReport(errors: errors, failedTests: failures, tests: counts)
    }

    /// `xcodebuild` の出力の抜粋。エラーらしい行（`error`・`failed`・`** … **`）があればそれを、無ければ末尾の行を残す。
    /// `preferringErrors` が false なら、いつも末尾の行を残す（理由が次の行に続く、短い出力の道具）
    func logExcerpt(of output: String, maximumLines: Int = 30, preferringErrors: Bool = true) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let errors = !preferringErrors ? [] : lines.filter { line in
            let lowered = line.lowercased()
            return lowered.contains("error") || lowered.contains("failed") || line.hasPrefix("** ")
        }
        let picked = (errors.isEmpty ? lines : errors).suffix(maximumLines)
        let text = clean(picked.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.suffix(Redaction.maximumExcerpt))
    }
}
