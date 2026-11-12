import AskHubProtocol
import Foundation

/// develop などのブランチの先頭の、`MARKETING_VERSION` を書いたファイル（版を上げる PR の材料）
public struct MarketingVersionSnapshot: Equatable, Sendable {
    /// `MARKETING_VERSION` を書いたファイル
    public struct File: Equatable, Sendable {
        /// リポジトリの直下からのパス
        public var path: String
        public var content: String

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }

        /// ファイルに書かれた版（`$(…)` などの変数は読まない）
        public var versions: [MarketingVersion] {
            MarketingVersionEdit.versions(in: content)
        }
    }

    /// ブランチの先頭のコミットと、その tree
    public var head: String
    public var tree: String
    public var files: [File]

    public init(head: String, tree: String, files: [File]) {
        self.head = head
        self.tree = tree
        self.files = files
    }

    /// ブランチの今の版（書かれた版のうち最も大きいもの）。どこにも書かれていなければ nil
    public var current: MarketingVersion? {
        files.flatMap(\.versions).max()
    }
}

/// 配信したコミットまでの変更（リリース文の材料）
public struct ReleaseChanges: Equatable, Sendable {
    /// 変更の 1 つ（base の first-parent のコミット）
    public struct Change: Equatable, Sendable {
        public var commit: String
        /// マージした PR の番号。PR のマージでなければ nil
        public var pullRequest: Int?
        /// PR の題（PR のマージ）か、コミットの 1 行目
        public var title: String

        public init(commit: String, pullRequest: Int? = nil, title: String) {
            self.commit = commit
            self.pullRequest = pullRequest
            self.title = title
        }
    }

    /// 変更を数え始めたタグ（配信したコミットに含まれる `v<版>` のタグのうち、この版より小さい最大のもの）。無ければ nil
    public var previousTag: String?
    /// 新しいものから順
    public var changes: [Change]
    /// 数の上限で切ったか
    public var truncated: Bool

    public init(previousTag: String?, changes: [Change], truncated: Bool = false) {
        self.previousTag = previousTag
        self.changes = changes
        self.truncated = truncated
    }
}

/// 配信の後作業が読む、対象のリポジトリの中身（本物は `GitRepositoryWorkspace`。テストでは差し替える）
public protocol ReleaseSourceReading: Sendable {
    /// base（nil なら既定のブランチ）の先頭の、アプリの Bundle ID の候補（`APP_BUNDLE_IDENTIFIER`・`PRODUCT_BUNDLE_IDENTIFIER` の値）
    func bundleIdentifiers(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> [String]
    /// base の先頭の、`MARKETING_VERSION` を書いたファイル
    func marketingVersions(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> MarketingVersionSnapshot
    /// 配信したコミットまでの変更
    func changes(
        _ repo: RepositoryFullName,
        upTo commit: String,
        below version: MarketingVersion
    ) async throws(WorkspaceError) -> ReleaseChanges
    /// 配信したコミットを取り出した、Claude に読ませる写し（`id` ごとに分ける）
    func prepare(_ repo: RepositoryFullName, commit: String, for id: ULID) async throws(WorkspaceError) -> PreparedWorkspace
    /// 写しを片付ける
    func release(_ id: ULID) async
}

/// `MARKETING_VERSION` の読み書き（`*.xcconfig` の `MARKETING_VERSION = 1.0.0`、`*.pbxproj` の `MARKETING_VERSION = 1.0.0;`・`"1.0.0";`、
/// `project.yml` の `MARKETING_VERSION: 1.0.0`・`"1.0.0"`）
public enum MarketingVersionEdit {
    /// `MARKETING_VERSION` の後の区切り（`=` か `:`）と、引用符を除いた値
    private static var pattern: Regex<(Substring, Substring)> { /MARKETING_VERSION[ \t]*[=:][ \t]*"?([0-9][0-9.]*)"?/ }

    /// ファイルに書かれた版。形の読めない値は飛ばす
    public static func versions(in content: String) -> [MarketingVersion] {
        content.matches(of: pattern).compactMap { MarketingVersion(rawValue: String($0.output.1)) }
    }

    /// `limit` 以下の版を `next` に書き換えた中身。書き換える所が無ければ nil
    public static func replacing(in content: String, atMost limit: MarketingVersion, with next: MarketingVersion) -> String? {
        var changed = false
        let result = content.replacing(pattern) { match -> String in
            let whole = String(match.output.0)
            guard let version = MarketingVersion(rawValue: String(match.output.1)), version <= limit else { return whole }
            changed = true
            return whole.replacingOccurrences(of: String(match.output.1), with: next.rawValue)
        }
        return changed ? result : nil
    }
}

/// Bundle ID の読み取り（`APP_BUNDLE_IDENTIFIER = jp.shilokuma.OshiCon`・`PRODUCT_BUNDLE_IDENTIFIER = "jp.shilokuma.AskHub";`・
/// `PRODUCT_BUNDLE_IDENTIFIER: jp.shilokuma.AskHub`）。`$(…)` などの変数を含む値は読まない
public enum BundleIdentifiers {
    private static var pattern: Regex<(Substring, Substring)> {
        /(?:APP_BUNDLE_IDENTIFIER|PRODUCT_BUNDLE_IDENTIFIER)[ \t]*[=:][ \t]*"?([A-Za-z0-9.\-]+)"?[ \t]*;?[ \t]*(?:\/\/.*)?$/
            .anchorsMatchLineEndings()
    }

    public static func values(in content: String) -> [String] {
        var values: [String] = []
        for match in content.matches(of: pattern) {
            let value = String(match.output.1)
            if AppStoreConnectClient.isBundleID(value), !values.contains(value) { values.append(value) }
        }
        return values
    }
}

/// 配信したコミットまでの変更を、git の first-parent の履歴から読む（`GitRepositoryWorkspace.changes`）
enum ReleaseHistory {
    /// `git log --format=%H%x1f%s%x1f%b%x1e` の出力から、変更を読む。GitHub の PR のマージ（`Merge pull request #12 from …`）は、
    /// 本文の 1 行目（PR の題）を題にする
    static func changes(fromLog log: String) -> [ReleaseChanges.Change] {
        log.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return nil }
            let commit = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard ReleaseFile.isCommit(commit) else { return nil }
            let subject = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let body = fields.count > 2 ? fields[2] : ""
            if let match = subject.wholeMatch(of: /Merge pull request #([0-9]+) from \S+/), let number = Int(match.output.1) {
                let title = body.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                return .init(commit: commit, pullRequest: number, title: title.isEmpty ? subject : title)
            }
            return .init(commit: commit, title: subject)
        }
    }

    /// 前のタグ: `v<版>` の形のタグのうち、`version` より小さい最大のもの
    static func previousTag(among tags: [String], below version: MarketingVersion) -> String? {
        tags.compactMap { tag -> (String, MarketingVersion)? in
            guard tag.hasPrefix("v"), let parsed = MarketingVersion(rawValue: String(tag.dropFirst())), parsed < version else { return nil }
            return (tag, parsed)
        }
        .max { $0.1 < $1.1 }?.0
    }
}

extension GitRepositoryWorkspace: ReleaseSourceReading {
    /// 読むファイルの数と大きさの上限（`*.pbxproj` は大きいことがある）
    static let maximumVersionFiles = 40
    static let maximumVersionFileSize = 2_000_000
    /// 読む変更の数の上限
    static let maximumReleaseChanges = 300

    public func bundleIdentifiers(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> [String] {
        var values: [String] = []
        for file in try await buildSettingFiles(repo, base: base).files {
            for value in BundleIdentifiers.values(in: file.content) where !values.contains(value) {
                values.append(value)
            }
        }
        return values
    }

    public func marketingVersions(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> MarketingVersionSnapshot {
        let snapshot = try await buildSettingFiles(repo, base: base)
        return MarketingVersionSnapshot(head: snapshot.head, tree: snapshot.tree, files: snapshot.files.filter { !$0.versions.isEmpty })
    }

    public func changes(
        _ repo: RepositoryFullName,
        upTo commit: String,
        below version: MarketingVersion
    ) async throws(WorkspaceError) -> ReleaseChanges {
        guard ReleaseFile.isCommit(commit) else { throw .failed("コミットの形が違う") }
        let clone = cloneDirectory(of: repo)
        var changes = ReleaseChanges(previousTag: nil, changes: [])
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            // 配信したコミットを指すタグは、ブランチの履歴と一緒には取れないことがあるので、タグもまとめて取る
            try await git(["fetch", "--tags", "--force", "origin"], in: clone)
            guard try await self.commit(of: commit, in: clone) != nil else { throw .failed("コミット \(commit) が clone に無い") }
            let tags = try await git(["tag", "--list", "v*", "--merged", commit], in: clone).split(separator: "\n").map(String.init)
            let previous = ReleaseHistory.previousTag(among: tags, below: version)
            let range = previous.map { "refs/tags/\($0)..\(commit)" } ?? commit
            let limit = Self.maximumReleaseChanges
            let log = try await git(["log", "--first-parent", "-n", String(limit + 1), "--format=%H%x1f%s%x1f%b%x1e", range], in: clone)
            let parsed = ReleaseHistory.changes(fromLog: log)
            changes = ReleaseChanges(previousTag: previous, changes: Array(parsed.prefix(limit)), truncated: parsed.count > limit)
        }
        return changes
    }

    public func prepare(_ repo: RepositoryFullName, commit: String, for id: ULID) async throws(WorkspaceError) -> PreparedWorkspace {
        guard ReleaseFile.isCommit(commit) else { throw .failed("コミットの形が違う") }
        let clone = cloneDirectory(of: repo)
        let worktree = jobDirectory(id).appendingPathComponent("repository/\(repo.name)", isDirectory: true)
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            guard try await self.commit(of: commit, in: clone) != nil else { throw .failed("コミット \(commit) が clone に無い") }
            try remove(worktree)
            try await git(["worktree", "prune"], in: clone)
            try await git(["worktree", "add", "--detach", "--force", worktree.path, commit], in: clone)
        }
        let claude = try? String(contentsOf: worktree.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        return PreparedWorkspace(directory: worktree, facts: claude.map(RepositoryFacts.extract) ?? "")
    }

    /// base の先頭の、ビルドの設定を書いたファイル（`*.xcconfig`・`*.pbxproj`・`project.yml`）。依存の置き場所の下は見ない
    private func buildSettingFiles(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> MarketingVersionSnapshot {
        let clone = cloneDirectory(of: repo)
        var snapshot = MarketingVersionSnapshot(head: "", tree: "", files: [])
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            let start = try await readingPoint(base: base, in: clone)
            let head = try await git(["rev-parse", "--verify", "\(start)^{commit}"], in: clone)
            let tree = try await git(["rev-parse", "--verify", "\(start)^{tree}"], in: clone)
            let listing = try await git(["ls-tree", "-r", "-l", "-z", head], in: clone)
            var files: [MarketingVersionSnapshot.File] = []
            for entry in Self.settingEntries(fromListing: listing).prefix(Self.maximumVersionFiles) {
                let result = try await run(["cat-file", "blob", entry.sha], in: clone)
                guard result.succeeded else { throw Self.classify(result, command: "cat-file") }
                guard let content = String(data: result.standardOutput, encoding: .utf8) else { continue }
                files.append(.init(path: entry.path, content: content))
            }
            snapshot = MarketingVersionSnapshot(head: head, tree: tree, files: files)
        }
        return snapshot
    }

    /// `git ls-tree -r -l -z` の出力から、ビルドの設定を書いたファイル（大きさの上限の中のもの）を選ぶ
    static func settingEntries(fromListing listing: String) -> [(path: String, sha: String)] {
        let ignored = ["Pods/", "Carthage/", ".build/", "DerivedData/", "SourcePackages/"]
        return listing.split(separator: "\0").compactMap { line in
            // `<mode> <type> <sha> <size>\t<path>`
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let fields = parts[0].split(separator: " ", omittingEmptySubsequences: true)
            let path = String(parts[1])
            guard fields.count == 4, fields[0] == "100644", fields[1] == "blob", let size = Int(fields[3]),
                  size <= maximumVersionFileSize, AppIconLocator.isSafeRelativePath(path),
                  !ignored.contains(where: { path.hasPrefix($0) || path.contains("/\($0)") }) else { return nil }
            let name = path.split(separator: "/").last.map(String.init) ?? path
            guard name.hasSuffix(".xcconfig") || name == "project.pbxproj" || name == "project.yml" else { return nil }
            return (path, String(fields[2]))
        }
    }
}
