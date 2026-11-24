import SwiftUI

extension View {
    /// 詳細の画面の題。iPhone は `navigationTitle` の大きな題で出す。
    /// Mac の 3 列の詳細の列には `navigationTitle` が出ない（ツールバーに置くと、一覧の列の題と並んで見分けにくい）ので、
    /// 詳細の列の中の上に、スクロールの端の効果のある帯で題を置く（何の画面かを分かるようにする）
    func detailTitle(_ title: String) -> some View {
        modifier(DetailTitleModifier(title: title))
    }
}

private struct DetailTitleModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .navigationTitle(title)
            .safeAreaBar(edge: .top, spacing: 0) {
                Text(title)
                    .appFont(.title2, weight: .bold)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 札の中の文字の先頭にそろえる
                    .padding(.horizontal, AppList.sideMargin + AppList.rowSideInset - AppList.platformRowInset)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
        #else
        content.navigationTitle(title)
        #endif
    }
}
