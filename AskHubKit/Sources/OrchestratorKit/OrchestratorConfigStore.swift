import Foundation

/// 設定の読み直しと、担当リポジトリの追加・削除。テストでは差し替える
public protocol OrchestratorConfigStore: Sendable {
    /// 設定を読み直す
    func load() throws -> OrchestratorConfig
    /// 担当リポジトリを足す。既にあれば何もしない
    func addRepository(_ fullName: String, checkoutPath: String) throws
    /// 担当リポジトリを外す。無ければ何もしない
    func removeRepository(_ fullName: String) throws
}

/// 設定ファイル（`~/.config/askhub/orchestrator.json`）の読み直しと、`repositories` の書き換え。
///
/// 書き換えるのは `repositories` だけで、ほかのキーは読んだ値のまま残す（キーの順と字下げは整え直す）。
/// 書く前に元のファイルを `<設定ファイル>.bak` に写し、検証できる形になることを確かめてから置き換える
public struct FileOrchestratorConfigStore: OrchestratorConfigStore {
    public let path: String
    private let loader: OrchestratorConfigLoader

    public init(path: String, loader: OrchestratorConfigLoader = OrchestratorConfigLoader()) {
        self.path = path
        self.loader = loader
    }

    public func load() throws -> OrchestratorConfig {
        try loader.load(from: path)
    }

    public func addRepository(_ fullName: String, checkoutPath: String) throws {
        try edit { entries in
            guard !entries.contains(where: { Self.matches($0, fullName) }) else {
                return false
            }
            entries.append(["repository": fullName, "path": abbreviatingHome(in: checkoutPath)])
            return true
        }
    }

    public func removeRepository(_ fullName: String) throws {
        try edit { entries in
            let count = entries.count
            entries.removeAll { Self.matches($0, fullName) }
            return entries.count != count
        }
    }

    /// `repositories` を書き換える。`change` が `false` を返せば書かない
    private func edit(_ change: (inout [[String: Any]]) -> Bool) throws {
        let url = URL(fileURLWithPath: loader.expandingTilde(in: path))
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entries = object["repositories"] as? [[String: Any]] else {
            throw OrchestratorConfigError.invalidJSON(reason: "repositories を書き換えられません")
        }
        guard change(&entries) else {
            return
        }
        object["repositories"] = entries
        let updated = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) + Data("\n".utf8)
        // 壊れた設定を書いて次の起動で止まらないよう、書く前に検証する
        _ = try loader.decode(updated)
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
        try updated.write(to: url, options: .atomic)
    }

    private static func matches(_ entry: [String: Any], _ fullName: String) -> Bool {
        (entry["repository"] as? String)?.caseInsensitiveCompare(fullName) == .orderedSame
    }

    /// ホームディレクトリの下なら `~/…` にする（手で書いた設定と同じ形にそろえる）
    private func abbreviatingHome(in path: String) -> String {
        let home = loader.homeDirectory
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
