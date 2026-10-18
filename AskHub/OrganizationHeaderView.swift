import SwiftUI

/// ステータスタブの organization の節の見出し。アバター画像と organization の login を並べる。
/// 画像の読み込み中・失敗時は代わりのアイコンを出し、名前の表示は変えない
struct OrganizationHeaderView: View {
    let organization: String
    let avatars: OrganizationAvatarStore

    var body: some View {
        HStack(spacing: 6) {
            avatar
                .frame(width: OrganizationAvatarStore.pointSize, height: OrganizationAvatarStore.pointSize)
                .clipShape(.rect(cornerRadius: 4))
                // 名前を読み上げるので、画像は飾りとして扱う
                .accessibilityHidden(true)
            // GitHub の login をそのまま出す（iOS の見出しの大文字への変換をしない）
            Text(organization)
                .textCase(nil)
        }
        .task(id: organization) { await avatars.load(organization) }
    }

    @ViewBuilder private var avatar: some View {
        if case let .loaded(image) = avatars.phase(for: organization) {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "building.2")
                .resizable()
                .scaledToFit()
                .padding(2)
                .foregroundStyle(.secondary)
        }
    }
}
