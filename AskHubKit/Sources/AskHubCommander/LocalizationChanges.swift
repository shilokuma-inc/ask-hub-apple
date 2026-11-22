import AskHubProtocol
import Foundation

/// 前に配信した版から文言が変わったアプリの言語（App Store のスクショで、ほかの言語を撮るかを決める。`docs/renewal/release.md` の「スクショ」）
public struct LocalizationChanges: Equatable, Sendable {
    /// 文言が変わったアプリの言語（`.lproj` のフォルダの名前・String Catalog の言語。`ja`・`zh-Hans` など）
    public var languages: Set<String>
    /// どの言語が変わったかを決められない変更があった（読めない String Catalog・`Base.lproj` の文言など）。すべての言語を変わったとみなす
    public var all: Bool

    public init(languages: Set<String> = [], all: Bool = false) {
        self.languages = languages
        self.all = all
    }

    /// すべての言語を変わったとみなす（比べ始める前の版のタグが無いときなど）
    public static let unknown = Self(all: true)

    /// アプリの言語（`build.storeScreenshots.languages` の `language`）の文言が変わったか。変わった言語そのものか、
    /// それを親に持つ言語（`en` が変われば `en-GB` も。地域の文言が無ければ親の言語の文言を使うため）なら変わったとみなす
    public func affects(_ language: String) -> Bool {
        if all { return true }
        let target = Self.normalized(language)
        return languages.contains { changed in
            let changed = Self.normalized(changed)
            return target == changed || target.hasPrefix(changed + "-")
        }
    }

    /// 大文字・小文字と `_`・`-` の違いをそろえる（`zh_Hans.lproj`・`pt-BR`）
    static func normalized(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

/// 文言のファイルの差から、変わった言語を求める（`GitRepositoryWorkspace.localizationChanges`）
enum LocalizationDiff {
    /// 読む String Catalog の数と大きさの上限。超えたら、すべての言語を変わったとみなす
    static let maximumCatalogs = 40
    static let maximumCatalogSize = 20_000_000
    /// 文言のファイル（`git diff` に渡す pathspec。`*` はフォルダの区切りもまたぐ）
    static let pathspecs = ["*.xcstrings", "*.strings", "*.stringsdict"]

    /// 変わったファイル（`git diff --raw`）の 1 つ
    struct Entry: Equatable {
        var path: String
        /// 前と後の blob。無い（足した・消した）か、ふつうのファイルでなければ nil
        var old: String?
        var new: String?
    }

    /// `git diff --raw -z --no-renames --no-abbrev` の出力を読む（`:<前の mode> <後の mode> <前の sha> <後の sha> <状態>\0<パス>\0`）
    static func entries(fromRaw raw: String) -> [Entry] {
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false)
        var entries: [Entry] = []
        var index = 0
        while index + 1 < fields.count {
            let header = fields[index].split(separator: " ")
            guard header.count == 5, header[0].hasPrefix(":") else {
                index += 1
                continue
            }
            func blob(mode: Substring, sha: Substring) -> String? {
                let isFile = mode == "100644" || mode == "100755"
                return isFile && sha.contains(where: { $0 != "0" }) ? String(sha) : nil
            }
            let old = blob(mode: header[0].dropFirst(), sha: header[2])
            entries.append(Entry(path: String(fields[index + 1]), old: old, new: blob(mode: header[1], sha: header[3])))
            index += 2
        }
        return entries
    }

    /// パスの文言のファイルの種類
    enum Kind: Equatable {
        /// String Catalog（中の言語ごとの値を比べる）
        case catalog
        /// 言語フォルダ（`ja.lproj` など）の `.strings`・`.stringsdict`（その言語が変わった）
        case strings(language: String)
        /// `Base.lproj` の `.strings`・`.stringsdict`（どの言語でも使われうる）
        case base
    }

    /// 文言のファイルでなければ nil（言語フォルダの外の `.strings` は、言語が決まらないので見ない）
    static func kind(of path: String) -> Kind? {
        let components = path.split(separator: "/")
        guard let name = components.last else { return nil }
        if name.hasSuffix(".xcstrings") { return .catalog }
        guard name.hasSuffix(".strings") || name.hasSuffix(".stringsdict"), components.count >= 2 else { return nil }
        let folder = components[components.count - 2]
        guard folder.hasSuffix(".lproj") else { return nil }
        let language = String(folder.dropLast(".lproj".count))
        guard !language.isEmpty else { return nil }
        return language == "Base" ? .base : .strings(language: language)
    }

    /// 変わったファイルから、変わった言語を求める。`read` は blob の中身（大きすぎれば nil）を返す
    static func changes(
        _ entries: [Entry],
        read: (String) async throws(WorkspaceError) -> Data?
    ) async throws(WorkspaceError) -> LocalizationChanges {
        var changes = LocalizationChanges()
        var catalogs: [Entry] = []
        for entry in entries {
            switch kind(of: entry.path) {
            case .catalog?: catalogs.append(entry)
            case let .strings(language)?: changes.languages.insert(language)
            case .base?: changes.all = true
            case nil: break
            }
        }
        guard !changes.all else { return changes }
        guard catalogs.count <= maximumCatalogs else { return .unknown }
        for catalog in catalogs {
            guard let languages = try await changedLanguages(catalog, read: read) else { return .unknown }
            changes.languages.formUnion(languages)
        }
        return changes
    }

    /// String Catalog の前と後の blob を読み、値が変わった言語を返す。読めなければ nil
    private static func changedLanguages(
        _ entry: Entry,
        read: (String) async throws(WorkspaceError) -> Data?
    ) async throws(WorkspaceError) -> Set<String>? {
        var datas: [Data?] = []
        for blob in [entry.old, entry.new] {
            guard let blob else {
                datas.append(nil)
                continue
            }
            guard let data = try await read(blob) else { return nil }
            datas.append(data)
        }
        return changedLanguages(old: datas[0], new: datas[1])
    }

    /// String Catalog の前と後（無ければ nil）で、値が変わった言語。読めなければ nil
    static func changedLanguages(old: Data?, new: Data?) -> Set<String>? {
        guard let before = values(in: old), let after = values(in: new) else { return nil }
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    /// String Catalog の、言語ごと・キーごとの値（無いファイルは空）。元の言語の値が書かれていないキーは、キーそのものを値とする。
    /// 訳の状態（`stringUnit` の `state`）は画面に出ないので比べない
    static func values(in data: Data?) -> [String: [String: JSONValue]]? {
        guard let data else { return [:] }
        guard let catalog = try? JSONDecoder().decode(StringCatalog.self, from: data) else { return nil }
        var values: [String: [String: JSONValue]] = [:]
        for (key, entry) in catalog.strings ?? [:] {
            let localizations = entry.localizations ?? [:]
            for (language, value) in localizations {
                values[language, default: [:]][key] = withoutStates(value)
            }
            if localizations[catalog.sourceLanguage] == nil {
                values[catalog.sourceLanguage, default: [:]][key] = .string(key)
            }
        }
        return values
    }

    /// `stringUnit` の `state` を除いた値
    private static func withoutStates(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(object):
            var result: [String: JSONValue] = [:]
            for (key, child) in object {
                if key == "stringUnit", case var .object(unit) = child {
                    unit["state"] = nil
                    result[key] = withoutStates(.object(unit))
                } else {
                    result[key] = withoutStates(child)
                }
            }
            return .object(result)
        case let .array(items):
            return .array(items.map(withoutStates))
        default:
            return value
        }
    }
}

/// String Catalog（`.xcstrings`）の、比べるのに使うところ
private struct StringCatalog: Decodable {
    struct Entry: Decodable {
        var localizations: [String: JSONValue]?
    }

    var sourceLanguage: String
    var strings: [String: Entry]?
}

extension GitRepositoryWorkspace {
    /// 前に配信した版のタグ（`tag`）から `commit` までに、文言が変わった言語（String Catalog の言語ごとの値・言語フォルダの `.strings`・`.stringsdict`）
    public func localizationChanges(
        _ repo: RepositoryFullName,
        from tag: String,
        to commit: String
    ) async throws(WorkspaceError) -> LocalizationChanges {
        guard ReleaseFile.isCommit(commit) else { throw .failed("コミットの形が違う") }
        guard tag.hasPrefix("v"), MarketingVersion(rawValue: String(tag.dropFirst())) != nil else { throw .failed("タグの形が違う") }
        let clone = cloneDirectory(of: repo)
        var changes = LocalizationChanges()
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            try await git(["fetch", "--tags", "--force", "origin"], in: clone)
            guard try await self.commit(of: commit, in: clone) != nil else { throw .failed("コミット \(commit) が clone に無い") }
            guard try await self.commit(of: "refs/tags/\(tag)", in: clone) != nil else { throw .failed("タグ \(tag) が clone に無い") }
            // 名前の変更として読むと blob を取りに行くので、消したものと足したものとして読む
            let raw = try await run(
                ["diff", "--raw", "-z", "--no-renames", "--no-abbrev", "refs/tags/\(tag)", commit, "--"] + LocalizationDiff.pathspecs,
                in: clone
            )
            guard raw.succeeded else { throw Self.classify(raw, command: "diff") }
            guard let output = String(bytes: raw.standardOutput, encoding: .utf8) else {
                changes = .unknown
                return
            }
            let entries = LocalizationDiff.entries(fromRaw: output)
            changes = try await LocalizationDiff.changes(entries) { blob throws(WorkspaceError) -> Data? in
                let size = try await git(["cat-file", "-s", blob], in: clone)
                guard let bytes = Int(size), bytes <= LocalizationDiff.maximumCatalogSize else { return nil }
                let result = try await run(["cat-file", "blob", blob], in: clone)
                guard result.succeeded else { throw Self.classify(result, command: "cat-file") }
                return result.standardOutput
            }
        }
        return changes
    }
}
