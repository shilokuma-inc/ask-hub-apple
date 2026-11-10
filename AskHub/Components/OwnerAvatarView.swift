import SwiftUI

/// リポジトリの持ち主（GitHub の organization かユーザー）のアバター。依頼のシートとリポジトリのタブで、どの organization のリポジトリかを見分けるために出す
struct OwnerAvatarView: View {
    let owner: String
    let avatar: RepositoryIcon
    /// テキストサイズが標準のときの大きさ。設定に合わせて伸び縮みする（ContentScale）
    var size: CGFloat = 20

    var body: some View {
        IconTile(icon: avatar, initial: owner.prefix(1).uppercased(), size: size)
    }
}

/// 持ち主のアバターと名前。リポジトリのタブの organization の見出しと、依頼のシートで選んだリポジトリの見出しに出す
struct OwnerLabel: View {
    let owner: String
    let avatar: RepositoryIcon
    /// 持ち主の名前の代わりに出す文字（例: owner/name）。nil なら持ち主の名前
    var title: String?
    var avatarSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 6) {
            OwnerAvatarView(owner: owner, avatar: avatar, size: avatarSize)
            // 一覧の見出しは既定で大文字になるが、GitHub の名前は書かれたとおりに出す
            Text(title ?? owner)
                .textCase(nil)
        }
    }
}

extension OwnerLabel {
    /// organization の見出し
    init(group: RepositoryOwnerGroup) {
        self.init(owner: group.owner, avatar: group.avatar)
    }

    /// リポジトリの持ち主のアバターと `owner/name`
    init(repository: TargetRepository, avatarSize: CGFloat = 16) {
        self.init(owner: repository.owner, avatar: repository.ownerAvatar, title: repository.fullName, avatarSize: avatarSize)
    }
}

#Preview("持ち主のアバター") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(RepositoryOwnerGroup.grouping(DemoData.repositories)) { group in
            OwnerLabel(group: group)
        }
        OwnerLabel(owner: "octocat", avatar: .monogram)
    }
    .padding()
}
