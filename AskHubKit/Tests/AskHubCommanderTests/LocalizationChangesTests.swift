@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import os
import Testing

/// 決めた出力を返し、流したコマンドを残す git（`diff` の出力と、blob ごとの中身）
final class ScriptedGit: CommandRunning {
    let raw: String
    let blobs: [String: Data]
    private let state = OSAllocatedUnfairLock<[[String]]>(initialState: [])

    init(raw: String, blobs: [String: Data]) {
        self.raw = raw
        self.blobs = blobs
    }

    var commands: [[String]] { state.withLock { $0 } }

    func run(_ command: Command) async throws -> CommandResult {
        state.withLock { $0.append(command.arguments) }
        let arguments = command.arguments
        var output = Data()
        if arguments.first == "diff" {
            output = Data(raw.utf8)
        } else if arguments.prefix(2) == ["cat-file", "-s"], let blob = blobs[arguments[2]] {
            output = Data(String(blob.count).utf8)
        } else if arguments.prefix(2) == ["cat-file", "blob"], let blob = blobs[arguments[2]] {
            output = blob
        }
        return CommandResult(status: 0, standardOutput: output, standardError: Data())
    }
}

/// 前に配信した版から文言が変わった言語の求め方（App Store のスクショ）
struct LocalizationChangesTests {
    static let repo = RepositoryFullName(rawValue: "shariverse/oshikatsu-countdown-ios")!
    static let commit = String(repeating: "b", count: 40)
    static let zero = String(repeating: "0", count: 40)

    /// String Catalog（キー → 言語 → 値。値が nil の言語は書かない）
    static func catalog(source: String = "ja", _ strings: [String: [String: String]]) throws -> Data {
        var entries: [String: Any] = [:]
        for (key, values) in strings {
            var localizations: [String: Any] = [:]
            for (language, value) in values {
                localizations[language] = ["stringUnit": ["state": "translated", "value": value]]
            }
            entries[key] = ["localizations": localizations]
        }
        let catalog: [String: Any] = ["sourceLanguage": source, "strings": entries, "version": "1.0"]
        return try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
    }

    /// `git diff --raw -z` の 1 件
    static func raw(_ path: String, old: String?, new: String?) -> String {
        let status = old == nil ? "A" : new == nil ? "D" : "M"
        return ":\(old == nil ? "000000" : "100644") \(new == nil ? "000000" : "100644") \(old ?? zero) \(new ?? zero) \(status)\0\(path)\0"
    }

    @Test func classifiesLocalizationFiles() {
        #expect(LocalizationDiff.kind(of: "OshiCon/Localizable.xcstrings") == .catalog)
        #expect(LocalizationDiff.kind(of: "OshiCon/Resources/zh-Hans.lproj/Localizable.strings") == .strings(language: "zh-Hans"))
        #expect(LocalizationDiff.kind(of: "en.lproj/Plurals.stringsdict") == .strings(language: "en"))
        #expect(LocalizationDiff.kind(of: "OshiCon/Base.lproj/Main.strings") == .base)
        // 言語フォルダの外の .strings と、言語フォルダのほかのファイルは見ない
        #expect(LocalizationDiff.kind(of: "Tools/Sample.strings") == nil)
        #expect(LocalizationDiff.kind(of: "OshiCon/ja.lproj/LaunchScreen.storyboard") == nil)
        #expect(LocalizationDiff.kind(of: "README.md") == nil)
    }

    @Test func readsRawDiff() {
        let old = String(repeating: "1", count: 40), new = String(repeating: "2", count: 40)
        let output = Self.raw("A/Localizable.xcstrings", old: old, new: new)
            + Self.raw("A/New.xcstrings", old: nil, new: new)
            + Self.raw("A/ja.lproj/Old.strings", old: old, new: nil)
            + ":100644 120000 \(old) \(new) T\0A/Linked.xcstrings\0"
        #expect(LocalizationDiff.entries(fromRaw: output) == [
            .init(path: "A/Localizable.xcstrings", old: old, new: new),
            .init(path: "A/New.xcstrings", old: nil, new: new),
            .init(path: "A/ja.lproj/Old.strings", old: old, new: nil),
            // シンボリックリンクになったものは、指す先のパスを読まない
            .init(path: "A/Linked.xcstrings", old: old, new: nil)
        ])
        #expect(LocalizationDiff.entries(fromRaw: "").isEmpty)
    }

    @Test func comparesCatalogValuesPerLanguage() throws {
        let old = try Self.catalog(["推し": ["en": "Oshi", "zh-Hans": "偶像"], "あと": ["en": "left"]])
        // 英語の値だけを変えた
        let changed = try Self.catalog(["推し": ["en": "Fave", "zh-Hans": "偶像"], "あと": ["en": "left"]])
        #expect(LocalizationDiff.changedLanguages(old: old, new: changed) == ["en"])
        // キーを足すと、元の言語（キーそのものが値）と、訳のある言語が変わる
        let added = try Self.catalog(["推し": ["en": "Oshi", "zh-Hans": "偶像"], "あと": ["en": "left"], "日": ["zh-Hans": "天"]])
        #expect(LocalizationDiff.changedLanguages(old: old, new: added) == ["ja", "zh-Hans"])
        // 消したファイル・足したファイルは、書かれていたすべての言語
        #expect(LocalizationDiff.changedLanguages(old: old, new: nil) == ["ja", "en", "zh-Hans"])
        #expect(LocalizationDiff.changedLanguages(old: nil, new: old) == ["ja", "en", "zh-Hans"])
        // 読めないファイルは決めない
        #expect(LocalizationDiff.changedLanguages(old: old, new: Data("<<<<<<< HEAD".utf8)) == nil)
    }

    @Test func ignoresTranslationStatesAndFormatting() throws {
        let old = try Self.catalog(["推し": ["en": "Oshi"]])
        var object = try #require(try JSONSerialization.jsonObject(with: old) as? [String: Any])
        var strings = try #require(object["strings"] as? [String: Any])
        strings["推し"] = ["localizations": ["en": ["stringUnit": ["state": "needs_review", "value": "Oshi"]]], "comment": "見出し"]
        object["strings"] = strings
        let reviewed = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        #expect(LocalizationDiff.changedLanguages(old: old, new: reviewed)?.isEmpty == true)
    }

    @Test func parentLanguageChangesAffectRegionalLanguages() {
        let changes = LocalizationChanges(languages: ["en", "zh_Hans"])
        #expect(changes.affects("en") && changes.affects("en-GB") && changes.affects("zh-Hans") && changes.affects("ZH-hans"))
        #expect(!changes.affects("zh-Hant") && !changes.affects("ja") && !changes.affects("eng"))
        #expect(!LocalizationChanges(languages: ["en-GB"]).affects("en"))
        #expect(LocalizationChanges.unknown.affects("ja"))
    }

    @Test func baseFoldersAndOversizedCatalogsMarkEveryLanguage() async throws {
        let blob = String(repeating: "1", count: 40)
        let base = [LocalizationDiff.Entry(path: "App/Base.lproj/Main.strings", old: blob, new: blob)]
        #expect(try await LocalizationDiff.changes(base) { _ throws(WorkspaceError) in nil }.all)
        let catalog = [LocalizationDiff.Entry(path: "App/Localizable.xcstrings", old: blob, new: blob)]
        // 大きすぎて読まなかった
        #expect(try await LocalizationDiff.changes(catalog) { _ throws(WorkspaceError) in nil } == .unknown)
        let many = (0...LocalizationDiff.maximumCatalogs).map { LocalizationDiff.Entry(path: "\($0).xcstrings", old: blob, new: nil) }
        #expect(try await LocalizationDiff.changes(many) { _ throws(WorkspaceError) in Data() } == .unknown)
    }

    @Test func workspaceDiffsLocalizationFilesFromThePreviousTag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalizationChangesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("repos/\(Self.repo.rawValue)/.git"), withIntermediateDirectories: true
        )
        let old = String(repeating: "1", count: 40), new = String(repeating: "2", count: 40)
        let git = ScriptedGit(
            raw: Self.raw("OshiCon/Localizable.xcstrings", old: old, new: new)
                + Self.raw("OshiCon/ko.lproj/InfoPlist.strings", old: old, new: new),
            blobs: [
                old: try Self.catalog(["推し": ["en": "Oshi", "fr": "Oshi"]]),
                new: try Self.catalog(["推し": ["en": "Oshi", "fr": "Idole"]])
            ]
        )
        let setup = GitRepositoryWorkspace.Setup(root: root, credentialHelper: "!'/opt/askhub/askhub-commander' git-credential")
        let workspace = GitRepositoryWorkspace(setup: setup, runner: git)
        let changes = try await workspace.localizationChanges(Self.repo, from: "v1.0.0", to: Self.commit)
        #expect(changes == LocalizationChanges(languages: ["fr", "ko"]))
        let diff = try #require(git.commands.first { $0.first == "diff" })
        #expect(diff == [
            "diff", "--raw", "-z", "--no-renames", "--no-abbrev", "refs/tags/v1.0.0", Self.commit, "--",
            "*.xcstrings", "*.strings", "*.stringsdict"
        ])
        #expect(git.commands.contains(["fetch", "--tags", "--force", "origin"]))
        // タグの形が違えば git を流さない
        await #expect(throws: WorkspaceError.self) {
            try await workspace.localizationChanges(Self.repo, from: "main", to: Self.commit)
        }
    }
}
