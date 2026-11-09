import AskHubProtocol
import Foundation

/// 取り出したリポジトリから、撮れる画面の一覧（`build.screenshots.scenes`）を読む
enum ScreenshotScenes {
    /// 一覧のファイルの大きさの上限
    static let maximumBytes = 256 * 1024

    /// 読めた一覧か、読めないわけ
    enum Loaded: Equatable {
        case scenes(ScreenshotScenesFile)
        case unavailable(String)

        var file: ScreenshotScenesFile? {
            guard case .scenes(let file) = self else { return nil }
            return file
        }
    }

    /// `checkout` の `path` を読む。リポジトリの外を指す（シンボリックリンクで外へ出るものを含む）・大きすぎる・形が違うものは読まない
    static func load(from checkout: URL, path: String) -> Loaded {
        let root = checkout.standardizedFileURL.resolvingSymlinksInPath()
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else { return .unavailable("撮れる画面の一覧（\(path)）がリポジトリの外を指している") }
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
            return .unavailable("撮れる画面の一覧（\(path)）が無い")
        }
        guard (values.fileSize ?? 0) <= maximumBytes, let data = try? Data(contentsOf: file) else {
            return .unavailable("撮れる画面の一覧（\(path)）が大きすぎるか、読めない")
        }
        guard let scenes = try? JSONDecoder().decode(ScreenshotScenesFile.self, from: data) else {
            return .unavailable("撮れる画面の一覧（\(path)）の形が違う")
        }
        if let problem = scenes.problems.first { return .unavailable("撮れる画面の一覧（\(path)）: \(problem)") }
        return .scenes(scenes)
    }
}
