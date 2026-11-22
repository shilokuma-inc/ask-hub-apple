import AskHubPullRequests
import Foundation

/// テンプレートから作ったリポジトリのアプリ名・Bundle ID の書き換え。テンプレートの `scripts/rename.sh` と同じ中身を、
/// clone せずに tree の上で行う（管理用のトークンを git に渡さないため。`docs/renewal/security.md` の「管理用のトークン」）。
///
/// - パスに元の名前（`OLD_NAME`）を含むファイルを、新しい名前のパスに移す
/// - テキストのファイルの中の元の名前と元のリポジトリ（`OLD_REPO`）を置き換える（`scripts/rename.sh` 自身は除く）
/// - `Configs/Project.xcconfig` の `APP_BUNDLE_IDENTIFIER` を、選んだ Bundle ID にする
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

    /// 書き換えた後のファイルの一覧（全部）。パスに元の名前を含むファイルが無ければ、書き換え済みとして nil
    static func plan(files: [TreeFile], texts: [String: String?], old: (name: String, repo: String), new: Names) -> [TreeFile]? {
        guard files.contains(where: { $0.path.contains(old.name) }) else { return nil }
        return files.map { file in
            var renamed = file
            renamed.path = file.path.replacingOccurrences(of: old.name, with: new.appName)
            guard file.type == "blob", file.path != scriptPath, let text = texts[file.sha].flatMap({ $0 }) else { return renamed }
            var content = text.replacingOccurrences(of: old.name, with: new.appName).replacingOccurrences(of: old.repo, with: new.repo)
            if file.path == configPath { content = Self.settingBundleId(new.bundleId, in: content) }
            if content != text { renamed.content = content }
            return renamed
        }
    }

    /// `APP_BUNDLE_IDENTIFIER = …` の行を置き換える
    static func settingBundleId(_ bundleId: String, in config: String) -> String {
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.hasPrefix("APP_BUNDLE_IDENTIFIER = ") ? "APP_BUNDLE_IDENTIFIER = \(bundleId)" : String(line)
        }
        return lines.joined(separator: "\n")
    }
}
