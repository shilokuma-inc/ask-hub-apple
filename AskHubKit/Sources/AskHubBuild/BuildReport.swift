import AskHubCommands
import Foundation

/// ビルドとテストの結果の要約。Claude に直させるときに渡す（`text(limit:)`）。
/// 中の文は、写しのパスを相対パスにし、トークンらしい文字列を伏せてある
public struct BuildReport: Equatable, Sendable {
    /// ビルドのエラー（警告は含めない）
    public var errors: [BuildIssue]
    /// 落ちたテスト
    public var failedTests: [FailedTest]
    /// テストの件数。テストを流していない・読めなかったときは nil
    public var tests: TestCounts?
    /// 結果のバンドルから理由を読めなかったときなどの、`xcodebuild` の出力の抜粋（エラーの行を優先した末尾）
    public var log: String?

    public init(errors: [BuildIssue] = [], failedTests: [FailedTest] = [], tests: TestCounts? = nil, log: String? = nil) {
        self.errors = errors
        self.failedTests = failedTests
        self.tests = tests
        self.log = log
    }

    /// `text(limit:)` の既定の上限（文字数）
    public static let defaultLimit = 4000
    /// 1 件の文の上限（文字数）
    static let itemLimit = 300
    /// 一覧に出す件数の上限
    static let maximumItems = 20

    /// Claude に渡す文。エラー・落ちたテスト・出力の抜粋の順に並べ、`limit` 文字で切る
    public func text(limit: Int = defaultLimit) -> String {
        var sections: [String] = []
        if !errors.isEmpty {
            sections.append(Self.section("ビルドのエラー（\(errors.count) 件）", errors.map(\.line)))
        }
        if !failedTests.isEmpty {
            let total = tests.map { " / 全 \($0.total) 件" } ?? ""
            sections.append(Self.section("落ちたテスト（\(failedTests.count) 件\(total)）", failedTests.map(\.line)))
        }
        if let log, !log.isEmpty {
            sections.append("xcodebuild の出力の抜粋:\n\(log)")
        }
        return Self.truncate(Redaction.redact(sections.joined(separator: "\n\n"), secrets: []), limit: limit)
    }

    private static func section(_ title: String, _ lines: [String]) -> String {
        var body = lines.prefix(maximumItems).map { "- " + truncate(collapse($0), limit: itemLimit) }
        if lines.count > maximumItems {
            body.append("- ほか \(lines.count - maximumItems) 件")
        }
        return ([title] + body).joined(separator: "\n")
    }

    /// 改行や続く空白を 1 つの空白にする（一覧の 1 行に収める）
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `limit` 文字を超えるなら、先頭を残して切り、切ったことを書く
    static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let marker = "…（長いので切った）"
        guard limit > marker.count else { return String(text.prefix(max(limit, 0))) }
        return String(text.prefix(limit - marker.count)) + marker
    }
}

/// ビルドのエラー 1 件
public struct BuildIssue: Equatable, Sendable {
    public var message: String
    /// エラーが出たターゲット
    public var target: String?
    /// 写しの直下からの相対パスと行（`AskHub/Foo.swift:12`）。分からなければ nil
    public var location: String?

    public init(message: String, target: String? = nil, location: String? = nil) {
        self.message = message
        self.target = target
        self.location = location
    }

    var line: String {
        let place = [location, target.map { "[\($0)]" }].compactMap { $0 }.joined(separator: " ")
        return place.isEmpty ? message : "\(place) \(message)"
    }
}

/// 落ちたテスト 1 件
public struct FailedTest: Equatable, Sendable {
    /// `<ターゲット>/<型>/<メソッド>` の形（`-only-testing:` に渡せる形）
    public var name: String
    public var message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }

    var line: String { "\(name): \(message)" }
}

/// テストの件数
public struct TestCounts: Equatable, Sendable {
    public var total: Int
    public var passed: Int
    public var failed: Int
    public var skipped: Int

    public init(total: Int, passed: Int, failed: Int, skipped: Int) {
        self.total = total
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
    }
}
