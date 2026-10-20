import Foundation

/// リリースのワークフロー（Discussion #605）。ファイル名と inputs はワークフロー側と約束したもの（ゴールの「既定の設計」）。
/// アプリは `GitHubWorkflow(client:file:)` にファイル名を渡し、ここで組み立てた inputs で起動する
public enum ReleaseWorkflow: String, Sendable, CaseIterable {
    /// リリース準備（`version`。任意で `resume`）。release ブランチの作成から App Store Connect への用意までを行う。`develop` から起動する
    case prepare = "release-prepare.yml"
    /// 最新情報の確定と反映（`version`・`whats_new`）
    case notes = "release-notes.yml"
    /// リリース後作業（`version`）。`main`・`develop` への取り込み・タグ・GitHub Release の公開。ふだんは `release-sync.yml` が起動する
    case finish = "release-finish.yml"
    /// ビルドの紐付けと配信の検知の定期実行（inputs なし）
    case sync = "release-sync.yml"

    /// ワークフローのファイル名（API の `workflow_id`）
    public var file: String {
        rawValue
    }

    /// このワークフローのクライアント
    public func client(_ client: GitHubClient) -> GitHubWorkflow {
        GitHubWorkflow(client: client, file: file)
    }

    /// リリース準備の inputs。`resume` は `true` のときだけ送る（ワークフローの既定は `false`）
    public static func prepareInputs(version: ReleaseVersion, resume: Bool = false) -> [String: String] {
        var inputs = ["version": version.description]
        if resume {
            inputs["resume"] = "true"
        }
        return inputs
    }

    /// 最新情報の確定の inputs。`whats_new` は言語コード → 本文の JSON の文字列（例: `{"ja":"…"}`）。
    /// 本文の検査（言語・4000 字まで・空でない）はワークフローが行う
    public static func notesInputs(version: ReleaseVersion, whatsNew: [String: String]) throws -> [String: String] {
        let encoder = JSONEncoder()
        // 同じ内容なら同じ文字列にする（ログで見比べやすく、テストで比べられる）
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSONEncoder の出力は UTF-8 なので nil にはならない
        let json = String(bytes: try encoder.encode(whatsNew), encoding: .utf8) ?? "{}"
        return ["version": version.description, "whats_new": json]
    }

    /// リリース後作業の inputs
    public static func finishInputs(version: ReleaseVersion) -> [String: String] {
        ["version": version.description]
    }
}
