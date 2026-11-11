import AskHubProtocol
import Foundation

/// 対象のアプリのアイコンの画像を、端末にしまっておく（`Library/Caches/AppIcons/<blob の sha>.png`）。
///
/// 鍵は画像の git の blob の sha（`repo.json` の `icon.image`）なので、同じ鍵の中身は変わらない。アイコンが変わったら鍵も変わるので、
/// 古いものは消さずに置いておく（変わるのはまれで、Caches は OS が片付ける）
nonisolated struct AppIconCache: Sendable {
    let directory: URL

    static let standard = Self(directory: URL.cachesDirectory.appending(path: "AppIcons", directoryHint: .isDirectory))

    func data(for version: String) -> Data? {
        guard let url = url(for: version) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// しまえなくても止めない（次に出すときに、状態リポジトリから読み直す）
    func store(_ data: Data, for version: String) {
        guard let url = url(for: version) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 鍵が git の sha の形（40 桁の 16 進）のときだけ、ファイルの場所にする（フォルダの外を指せないように）
    private func url(for version: String) -> URL? {
        guard AttemptFile.isCommitSHA(version) else { return nil }
        return directory.appending(path: "\(version).png", directoryHint: .notDirectory)
    }
}
