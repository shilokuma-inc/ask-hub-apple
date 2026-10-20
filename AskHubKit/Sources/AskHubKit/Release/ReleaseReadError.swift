import Foundation

/// リリースの読み取り（`GitHubReleaseReader`）で起きるエラー。`GitHubError` の HTTP の状態から、アプリで表示を分けるものを区別する。
/// レート制限（403 / 429）は `GitHubError.rateLimited` のままで、ここには来ない
public enum ReleaseReadError: Error, Equatable, Sendable {
    /// トークンに Contents の Read が無い（レート制限でない 403）。アプリのトークンには Actions の Read and write に加えて Contents の Read を求める
    case permissionDenied
    /// release ブランチ・タグの一覧が 404。トークンからリポジトリが見えない
    case repositoryNotFound
    /// 読むファイル（`Configs/Project.xcconfig` など）が `ref` に無い（404）。`ref` のブランチが無いときも 404 になる
    case fileNotFound(path: String, ref: String)
    /// `Configs/Project.xcconfig` に `MARKETING_VERSION` が無い
    case marketingVersionNotFound
    /// 最新情報の下書きの `schemaVersion` が、このアプリの知らない値。読まずに知らせる（アプリを新しくする）
    case unsupportedDraftSchema(Int)
    /// ファイルの中身を読めない（ディレクトリ・1 MB を超えて本文が返らない・JSON の形が違う など）
    case invalidContent(path: String)
}
