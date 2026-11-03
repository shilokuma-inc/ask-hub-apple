import Foundation

/// 対象のリポジトリ（AskHub でループ開発を回すリポジトリ）。
///
/// 画面用のモデル。AskHubKit のプロトコルの型とは分けてあり、バックエンドにつなぐときは変換を 1 か所に書く
struct TargetRepository: Identifiable, Hashable {
    /// `owner/name` を小文字にしたもの（一覧の id が大文字小文字の違いで重ならないように）
    var id: String { fullName.lowercased() }
    let owner: String
    let name: String
    /// アプリの表示名。カードや一覧で、どのアプリの判断かを一目で分かるようにアイコンと並べて出す
    var appName: String
    var icon: RepositoryIcon
    /// 前回このリポジトリを回した Mac。開始のときに既定で選ぶ。まだ回していなければ nil
    var lastMacID: Mac.ID?

    var fullName: String { "\(owner)/\(name)" }
}

/// アプリのアイコン。対象に加えるときとアイコンが変わったときに、司令塔かワーカーが画像を取り出して状態リポジトリに置く想定
enum RepositoryIcon: Hashable {
    /// 状態リポジトリに置いた画像
    case image(URL)
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
