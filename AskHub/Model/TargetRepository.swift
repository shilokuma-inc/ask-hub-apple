import Foundation

/// 対象のリポジトリ（AskHub でループ開発を回すリポジトリ）。
///
/// 画面用のモデル。AskHubKit のプロトコルの型とは分けてあり、バックエンドにつなぐときは変換を 1 か所に書く
struct TargetRepository: Identifiable, Hashable {
    /// `owner/name` を小文字にしたもの（一覧の id が大文字小文字の違いで重ならないように）
    var id: String { fullName.lowercased() }
    let owner: String
    /// 持ち主（GitHub の organization かユーザー）のアイコン。依頼のシートとリポジトリのタブで、どの organization のリポジトリかを見分けられるように出す
    var ownerAvatar: RepositoryIcon = .monogram
    let name: String
    /// アプリの表示名。カードや一覧で、どのアプリの判断かを一目で分かるようにアイコンと並べて出す
    var appName: String
    var icon: RepositoryIcon
    /// 前回このリポジトリを回した Mac。開始のときに既定で選ぶ。まだ回していなければ nil
    var lastMacID: Mac.ID?

    var fullName: String { "\(owner)/\(name)" }

    /// GitHub の PR の画面
    func pullRequestURL(_ number: Int) -> URL? {
        URL(string: "https://github.com/\(fullName)/pull/\(number)")
    }
}

/// 持ち主（GitHub の organization かユーザー）ごとにまとめた対象のリポジトリ。依頼のシートとリポジトリのタブで、見出しを付けて並べる
struct RepositoryOwnerGroup: Identifiable, Hashable {
    /// 小文字にした持ち主（GitHub の login は大文字小文字を区別しない）
    var id: String { owner.lowercased() }
    /// 見出しに出す持ち主。大文字小文字だけ違う書き方が混ざっていたら、先に並ぶリポジトリの書き方にする
    let owner: String
    let avatar: RepositoryIcon
    let repositories: [TargetRepository]

    /// 持ち主ごとにまとめる。持ち主も中のリポジトリ（アプリ名）も名前順にする（ユーザーの決定。2026-11-11）
    static func grouping(_ repositories: [TargetRepository]) -> [RepositoryOwnerGroup] {
        let groups = Dictionary(grouping: repositories) { $0.owner.lowercased() }.values.map { members in
            let sorted = members.sorted { inNameOrder([$0.appName, $0.name, $0.id], [$1.appName, $1.name, $1.id]) }
            return RepositoryOwnerGroup(owner: sorted[0].owner, avatar: sorted[0].ownerAvatar, repositories: sorted)
        }
        return groups.sorted { inNameOrder([$0.owner, $0.id], [$1.owner, $1.id]) }
    }

    /// 名前の順（Finder と同じく大文字小文字を区別せず、数字は数として比べる）。前の名前が同じなら次の名前で比べる
    private static func inNameOrder(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) {
            let order = left.localizedStandardCompare(right)
            if order != .orderedSame {
                return order == .orderedAscending
            }
        }
        return false
    }
}

/// アプリのアイコンと、持ち主のアバター。アプリのアイコンは、司令塔が対象のリポジトリから取り出して状態リポジトリに置く（`repo.json` の `icon`）
enum RepositoryIcon: Hashable {
    /// URL でそのまま読める画像（GitHub の持ち主のアバター）
    case image(URL)
    /// 司令塔が状態リポジトリに置いた画像（`path`）。`version` は画像の git の blob の sha で、端末にしまっておく鍵にする
    case stored(path: String, version: String)
    /// デモのデータ用に描くアイコン（SF Symbols と色）
    case symbol(String, IconTint)
    /// 画像がまだ無い。アプリ名の頭文字で代わりのアイコンを描く
    case monogram
}

/// アイコンの色。画面用のモデルは SwiftUI に依存させないので、色は名前で持つ
enum IconTint: String, Hashable, CaseIterable {
    case green
    case orange
    case blue
    case purple
    case pink
    case teal
    case indigo
    case gray
}
