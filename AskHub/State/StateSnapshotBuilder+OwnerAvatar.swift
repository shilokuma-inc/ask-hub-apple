import AskHubProtocol
import Foundation

// MARK: - 持ち主のアバター

extension StateSnapshotBuilder {
    /// 持ち主の GitHub のアバター（`https://github.com/<owner>.png` は画像へ転送する）。public の画像なので、トークンを付けずに読む。
    /// 持ち主の名前は `RepositoryFullName` が英数字とハイフンだけに限っているので、そのまま URL に入れられる
    static func ownerAvatar(of repo: RepositoryFullName) -> RepositoryIcon {
        URL(string: "https://github.com/\(repo.owner).png?size=\(ownerAvatarPixels)").map { .image($0) } ?? .monogram
    }

    /// アバターを取り寄せる大きさ（画素）。見出しに出す 20pt ほどを 3 倍の画面でも粗くなく描ける
    static let ownerAvatarPixels = 96
}
