import Foundation

/// release ブランチ（`release/<バージョン>`）かタグ（`v<バージョン>`）の 1 つ
public struct ReleaseRef: Sendable, Hashable {
    /// `refs/heads/`・`refs/tags/` を外した名前（`release/1.1.0`・`v1.1.0`）
    public var name: String
    /// 指しているオブジェクトの SHA。注釈付きのタグではタグのオブジェクトの SHA（コミットではない）
    public var sha: String
    /// 名前から読んだバージョン。`release/foo`・`very-old` のように形が違えば `nil`
    public var version: ReleaseVersion?

    public init(name: String, sha: String, version: ReleaseVersion?) {
        self.name = name
        self.sha = sha
        self.version = version
    }
}

/// リポジトリの release ブランチとタグの一覧（`git/matching-refs/heads/release/`・`git/matching-refs/tags/v`）。
/// アプリは App Store Connect を見られないので、リリースの進み具合はこの一覧と run・下書きのファイルだけから出す
public struct ReleaseRefs: Sendable, Equatable {
    /// release ブランチ（`release/` で始まるもの。形が違うものも含む）
    public var branches: [ReleaseRef]
    /// `v` で始まるタグ（形が違うものも含む）
    public var tags: [ReleaseRef]

    public init(branches: [ReleaseRef], tags: [ReleaseRef]) {
        self.branches = branches
        self.tags = tags
    }

    /// `version` の release ブランチ
    public func branch(for version: ReleaseVersion) -> ReleaseRef? {
        branches.first { $0.version == version }
    }

    /// `version` のタグ（`v<バージョン>`）
    public func tag(for version: ReleaseVersion) -> ReleaseRef? {
        tags.first { $0.version == version }
    }

    /// `version` の release ブランチかタグがすでにあるか。あればリリース準備を始めない（ゴールの「既定の設計」）。
    /// リリース準備のワークフローは、タグの無い別の release ブランチがあるときも止まる。起動の前には `unreleasedVersions` が空かも見る
    public func isTaken(_ version: ReleaseVersion) -> Bool {
        branch(for: version) != nil || tag(for: version) != nil
    }

    /// release ブランチがあってタグがまだ無いバージョン（準備中・配信待ちのリリース）。小さい順
    public var unreleasedVersions: [ReleaseVersion] {
        Set(branches.compactMap(\.version).filter { tag(for: $0) == nil }).sorted()
    }

    /// タグのうち最も大きいバージョン（リリース済みの最新）。無ければ `nil`
    public var latestTaggedVersion: ReleaseVersion? {
        tags.compactMap(\.version).max()
    }
}
