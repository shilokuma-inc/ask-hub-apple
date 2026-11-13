import Foundation

/// 状態リポジトリのファイルのパス（`docs/renewal/protocol.md` の「ファイルの置き方」）。
///
/// パスの部品は、形を確かめた型（`RepositoryFullName`・`ULID`・`MacName`・`KeyID`）からだけ作る
public enum StatePath {
    public static let version = "version.json"
    public static let commander = "commander.json"
    /// 進行を止めるものを知らせた記録（司令塔）
    public static let notifications = "notifications.json"

    /// 対象のリポジトリを置くディレクトリ（`repos/<owner>/<repo>/`）
    public static let repositories = "repos"

    public static func repository(_ repo: RepositoryFullName) -> String {
        "\(repositoryDirectory(repo))/repo.json"
    }

    /// 対象のアプリのアイコンの画像（PNG。`repo.json` の `icon`）
    public static func appIcon(_ repo: RepositoryFullName) -> String {
        "\(repositoryDirectory(repo))/icon.png"
    }

    public static func epic(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/epic.json"
    }

    public static func questions(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/questions.json"
    }

    public static func goal(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/goal.json"
    }

    public static func readiness(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/readiness.json"
    }

    /// 人が決めていない判断（ループの仮決め）の一覧
    public static func decisions(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/decisions.json"
    }

    /// 実機確認への答え
    public static func verifications(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/verifications.json"
    }

    /// 撮影のジョブが撮った画像（`<コミット>-<画面>.png`）。Before は base との分岐点、After は作業ブランチの先頭のコミットで、
    /// 同じコミット・画面は撮り直さずに使い回す（いくつかの仮決めが同じ画像を指すことがある）
    public static func screenshot(_ repo: RepositoryFullName, _ epic: ULID, commit: String, scene: String) -> String {
        "\(epicDirectory(repo, epic))/screenshots/\(commit)-\(scene).png"
    }

    /// App Store で配信した版の記録を置くディレクトリ（`releases/<版>.json`）
    public static func releases(_ repo: RepositoryFullName) -> String {
        "\(repositoryDirectory(repo))/releases"
    }

    /// App Store で配信した版と、その後作業の進み具合
    public static func release(_ repo: RepositoryFullName, _ version: MarketingVersion) -> String {
        "\(releases(repo))/\(version.rawValue).json"
    }

    /// リポジトリの epic を置くディレクトリ（`epics/<epic>/`）
    public static func epics(_ repo: RepositoryFullName) -> String {
        "\(repositoryDirectory(repo))/epics"
    }

    /// epic のジョブを置くディレクトリ
    public static func jobs(_ repo: RepositoryFullName, epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/jobs"
    }

    /// 人の意図を置くディレクトリ（端末ごとに `intents/<device>/` に分ける）
    public static let intents = "intents"

    /// 処理した人の意図の記録を置くディレクトリ（`consumed/<device>/`）
    public static let consumedDirectory = "consumed"

    public static func job(_ repo: RepositoryFullName, epic: ULID, job: ULID) -> String {
        "\(epicDirectory(repo, epic))/jobs/\(job).json"
    }

    /// ジョブの試行を置くディレクトリ
    public static func attempts(_ repo: RepositoryFullName, epic: ULID, job: ULID) -> String {
        "\(epicDirectory(repo, epic))/attempts/\(job)"
    }

    public static func attempt(_ repo: RepositoryFullName, epic: ULID, job: ULID, number: Int) -> String {
        precondition(number >= 1, "試行の番号は 1 から")
        return "\(epicDirectory(repo, epic))/attempts/\(job)/\(number).json"
    }

    public static func mac(_ mac: MacName) -> String {
        "macs/\(mac).json"
    }

    /// 通知の宛先を置くディレクトリ
    public static let devices = "devices"

    public static func device(_ device: KeyID) -> String {
        "\(devices)/\(device).json"
    }

    /// 公開鍵の記録を置くディレクトリ
    public static let keys = "keys"

    /// 公開鍵の記録（`seq` は 1 から）
    public static func key(seq: Int) -> String {
        precondition(seq >= 1, "公開鍵の記録の番号は 1 から")
        return "\(keys)/\(seq).json"
    }

    /// 公開のスレッドに置かない人の意図
    public static func intent(device: KeyID, nonce: ULID) -> String {
        "intents/\(device)/\(nonce).json"
    }

    /// 依頼の添付（`number` は 1 から）
    public static func attachment(device: KeyID, nonce: ULID, number: Int) -> String {
        precondition(number >= 1, "添付の番号は 1 から")
        return "attachments/\(device)/\(nonce)/\(number)"
    }

    /// 処理した人の意図の記録
    public static func consumed(device: KeyID, nonce: ULID) -> String {
        "consumed/\(device)/\(nonce).json"
    }

    private static func repositoryDirectory(_ repo: RepositoryFullName) -> String {
        "\(repositories)/\(repo.owner)/\(repo.name)"
    }

    private static func epicDirectory(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(repositoryDirectory(repo))/epics/\(epic)"
    }
}
