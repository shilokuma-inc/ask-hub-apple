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

    private static func repositoryDirectory(_ repo: RepositoryFullName) -> String {
        "repos/\(repo.owner)/\(repo.name)"
    }

    private static func epicDirectory(_ repo: RepositoryFullName, _ epic: ULID) -> String {
        "\(repositoryDirectory(repo))/epics/\(epic)"
    }
}
