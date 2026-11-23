import AskHubPullRequests
import Foundation

/// テンプレートから作ったリポジトリのアプリ名・Bundle ID の書き換え。テンプレートの `scripts/rename.sh` と同じ中身を、
/// clone せずに tree の上で行う（管理用のトークンを git に渡さないため。`docs/renewal/security.md` の「管理用のトークン」）。
///
/// - パスに元の名前（`OLD_NAME`）を含むファイルを、新しい名前のパスに移す
/// - テキストのファイルの中の元の名前と元のリポジトリ（`OLD_REPO`）を置き換える（`scripts/rename.sh` 自身は除く）
/// - `Configs/Project.xcconfig` の `APP_BUNDLE_IDENTIFIER` を、選んだ Bundle ID にする
/// - 書き換えた Swift のファイルの import を並べ直す（テンプレートの `@testable import IOSTemplateApp` は Foundation と Testing の間にあり、
///   新しい名前によっては SwiftLint の `sorted_imports` で CI が落ちるため。`rename.sh` の後に人が直していたもの）
enum TemplateRename {
    static let scriptPath = "scripts/rename.sh"
    static let configPath = "Configs/Project.xcconfig"

    /// `scripts/rename.sh` の `OLD_NAME="…"`・`OLD_REPO="…"`。読めなければ nil
    static func oldNames(in script: String) -> (name: String, repo: String)? {
        func value(_ key: String) -> String? {
            for line in script.split(whereSeparator: \.isNewline) where line.hasPrefix("\(key)=\"") && line.hasSuffix("\"") {
                let value = line.dropFirst(key.count + 2).dropLast()
                return value.isEmpty || value.contains("\"") ? nil : String(value)
            }
            return nil
        }
        guard let name = value("OLD_NAME"), let repo = value("OLD_REPO") else { return nil }
        return (name, repo)
    }

    /// 中身を読むファイル（パスでバイナリと分かるものは読まない）
    static func needsText(_ file: TreeFile) -> Bool {
        guard file.type == "blob", file.mode != "120000" else { return false }
        let binary: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "pdf", "usdz", "reality", "ttf", "otf", "zip", "car", "mp4", "mov"]
        return !binary.contains((file.path as NSString).pathExtension.lowercased())
    }

    /// 書き換えた後の名前
    struct Names {
        var appName: String
        /// 作ったリポジトリの `owner/name`
        var repo: String
        var bundleId: String
    }

    /// 名前の書き換えの様子。部分一致で見ると、元の名前を含むアプリ名（`IOSTemplateAppPlus`）で二重に書き換えてしまうので、
    /// プロジェクトのファイルがどちらの名前にあるかで見る
    enum Progress: Equatable {
        /// テンプレートのまま（元の名前のプロジェクトがある）
        case template
        /// 選んだアプリ名に書き換えてある
        case renamed
    }

    /// プロジェクトのファイル（`<名前>.xcodeproj/project.pbxproj`）
    static func projectFile(_ name: String) -> String {
        "\(name).xcodeproj/project.pbxproj"
    }

    /// 書き換えの様子。どちらの名前のプロジェクトも無ければ nil（テンプレートから作ったままの形でない）
    static func progress(of files: [TreeFile], oldName: String, appName: String) -> Progress? {
        let paths = Set(files.map(\.path))
        if paths.contains(projectFile(oldName)) { return .template }
        if paths.contains(projectFile(appName)) { return .renamed }
        return nil
    }

    /// `Configs/Project.xcconfig` の `APP_BUNDLE_IDENTIFIER`。無ければ nil
    static func bundleId(in config: String) -> String? {
        let prefix = "APP_BUNDLE_IDENTIFIER = "
        let line = config.split(separator: "\n").first { $0.hasPrefix(prefix) }
        return line.map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    /// 書き換えた後のファイルの一覧（全部）。テンプレートのまま（`progress` が `template`）のときだけ呼ぶ
    static func plan(files: [TreeFile], texts: [String: String?], old: (name: String, repo: String), new: Names) -> [TreeFile] {
        files.map { file in
            var renamed = file
            renamed.path = file.path.replacingOccurrences(of: old.name, with: new.appName)
            guard file.type == "blob", file.path != scriptPath, let text = texts[file.sha].flatMap({ $0 }) else { return renamed }
            var content = text.replacingOccurrences(of: old.name, with: new.appName).replacingOccurrences(of: old.repo, with: new.repo)
            if file.path == configPath { content = Self.settingBundleId(new.bundleId, in: content) }
            if file.path.hasSuffix(".swift"), content != text { content = Self.sortingImports(content) }
            if content != text { renamed.content = content }
            return renamed
        }
    }

    /// 続いた import の行（`import X`・`@testable import X` など）を、モジュール名の順（大文字小文字を区別しない）に並べ直す。
    /// 空の行やほかの行で区切られた並びは、それぞれの中だけで並べる（SwiftLint の `sorted_imports` と同じ見方）
    static func sortingImports(_ source: String) -> String {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var start = 0
        while start < lines.count {
            guard importedModule(lines[start]) != nil else {
                start += 1
                continue
            }
            var end = start
            while end < lines.count, importedModule(lines[end]) != nil { end += 1 }
            let sorted = lines[start..<end].sorted { (importedModule($0) ?? "").lowercased() < (importedModule($1) ?? "").lowercased() }
            lines.replaceSubrange(start..<end, with: sorted)
            start = end
        }
        return lines.joined(separator: "\n")
    }

    /// import の行なら、そのモジュール名（`@testable` などの属性と `import` の種類を除く）。import の行でなければ nil
    private static func importedModule(_ line: String) -> String? {
        let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ").filter { !$0.hasPrefix("@") }
        guard words.first == "import", words.count >= 2 else { return nil }
        // `import struct Foundation.Date` のような種類つきの import は、最後の語がモジュール名
        return String(words[words.count - 1])
    }

    /// `APP_BUNDLE_IDENTIFIER = …` の行を置き換える
    static func settingBundleId(_ bundleId: String, in config: String) -> String {
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("APP_BUNDLE_IDENTIFIER = ") ? "APP_BUNDLE_IDENTIFIER = \(bundleId)" : String(line)
        }
        return lines.joined(separator: "\n")
    }
}
