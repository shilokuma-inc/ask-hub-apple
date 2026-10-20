import Foundation

/// リリースのバージョン（`MAJOR.MINOR.PATCH`。0 以上の整数 3 つ。Discussion #605 の Q2）。
/// release ブランチは `release/<バージョン>`、タグは `v<バージョン>`。形の決まりはリリース準備のワークフロー（`release-prepare.yml`）の入力の検査と同じで、
/// 先頭の 0（`01`）・符号・空白・`1.0` のような 2 つの数は認めない
public struct ReleaseVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// 各数は 0 以上。負の値は 0 にする
    public init(major: Int, minor: Int, patch: Int) {
        self.major = max(major, 0)
        self.minor = max(minor, 0)
        self.patch = max(patch, 0)
    }

    /// `MAJOR.MINOR.PATCH` の文字列を読む。形が違えば `nil`（アプリの入力欄の検査にも使う）
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        var numbers: [Int] = []
        for part in parts {
            // ASCII の数字だけ（全角数字や符号を Int(_:) に通さない）。先頭の 0 は 0 そのものだけ認める
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  part == "0" || !part.hasPrefix("0"),
                  let number = Int(part) else {
                return nil
            }
            numbers.append(number)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    /// release ブランチの名前（`release/1.1.0`）から読む。違う形なら `nil`
    public init?(branch: String) {
        guard branch.hasPrefix(Self.branchPrefix) else {
            return nil
        }
        self.init(String(branch.dropFirst(Self.branchPrefix.count)))
    }

    /// タグの名前（`v1.1.0`）から読む。違う形なら `nil`
    public init?(tag: String) {
        guard tag.hasPrefix(Self.tagPrefix) else {
            return nil
        }
        self.init(String(tag.dropFirst(Self.tagPrefix.count)))
    }

    /// release ブランチの接頭辞
    public static let branchPrefix = "release/"
    /// タグの接頭辞
    public static let tagPrefix = "v"

    /// `1.1.0` の形
    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    /// 次のマイナー（`1.0.3` → `1.1.0`）。アプリの「リリース準備」のバージョンの既定値（`develop` の `MARKETING_VERSION` の次のマイナー）
    public var nextMinor: Self {
        Self(major: major, minor: minor + 1, patch: 0)
    }

    /// release ブランチの名前（`release/1.1.0`）
    public var branchName: String {
        Self.branchPrefix + description
    }

    /// タグの名前（`v1.1.0`）
    public var tagName: String {
        Self.tagPrefix + description
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
