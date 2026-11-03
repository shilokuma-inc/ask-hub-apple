import Foundation

/// 状態リポジトリのファイルのパス（`docs/renewal/protocol.md` の「ファイルの置き方」）。
///
/// パスの部品は、形を確かめた型（`RepositoryFullName`・`ULID`・`MacName`・`KeyID`）からだけ作る
public enum StatePath {
    public static let version = "version.json"
    public static let commander = "commander.json"

    public static func repository(_ repo: RepositoryFullName) -> String {
        "\(repositoryDirectory(repo))/repo.json"
    }

    public static func epic(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(epicDirectory(repo, epic))/epic.json"
    }

    public static func job(_ repo: RepositoryFullName, epic: ULID, job: ULID) -> String {
        "\(epicDirectory(repo, epic))/jobs/\(job).json"
    }

    public static func attempt(_ repo: RepositoryFullName, epic: ULID, job: ULID, number: Int) -> String {
        precondition(number >= 1, "試行の番号は 1 から")
        return "\(epicDirectory(repo, epic))/attempts/\(job)/\(number).json"
    }

    public static func mac(_ mac: MacName) -> String {
        "macs/\(mac).json"
    }

    public static func device(_ device: KeyID) -> String {
        "devices/\(device).json"
    }

    /// 公開鍵の記録（`seq` は 1 から）
    public static func key(seq: Int) -> String {
        precondition(seq >= 1, "公開鍵の記録の番号は 1 から")
        return "keys/\(seq).json"
    }

    /// 公開のスレッドに置かない人の意図
    public static func intent(device: KeyID, nonce: ULID) -> String {
        "intents/\(device)/\(nonce).json"
    }

    /// 処理した人の意図の記録
    public static func consumed(device: KeyID, nonce: ULID) -> String {
        "consumed/\(device)/\(nonce).json"
    }

    private static func repositoryDirectory(_ repo: RepositoryFullName) -> String {
        "repos/\(repo.owner)/\(repo.name)"
    }

    private static func epicDirectory(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(repositoryDirectory(repo))/epics/\(epic)"
    }
}
