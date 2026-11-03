import SwiftUI

/// 一覧の余白と行の文字。標準の List はセクションの間と行の上下の余白が広く、一画面に入る行が少ないので詰める
/// （ユーザーの要望。2026-11-03）。行の当たりは HIG の 44pt を下回らない
enum AppList {
    /// 行の上下の余白（標準はおよそ 11pt）
    static let rowVerticalInset: CGFloat = 7
    /// セクションの間（標準の `.default` より狭い）
    static let sectionSpacing: CGFloat = 16
}

/// 一覧の行の文字の役割。標準の text style より一段小さくする（行の見出しを headline から下げた。ユーザーの要望。2026-11-03）
enum RowFont {
    /// 行の見出し（標準で 15pt の太字）
    case title
    /// 見出しの下の 1 行目（標準で 13pt）
    case subtitle
    /// 補足（標準で 12pt）
    case detail
}

extension View {
    /// 一覧の行の文字（RowFont）
    func rowFont(_ role: RowFont) -> some View {
        switch role {
        case .title: appFont(.subheadline, weight: .semibold)
        case .subtitle: appFont(.footnote)
        case .detail: appFont(.caption)
        }
    }

    /// 一覧の余白を詰める（List に付ける）。Mac の一覧はもともと詰まっていて、セクションの間の指定も無いので、そのままにする
    @ViewBuilder func compactList() -> some View {
        #if os(iOS)
        listSectionSpacing(AppList.sectionSpacing)
            .environment(\.defaultMinListRowHeight, 44)
        #else
        self
        #endif
    }

    /// 一覧の行の上下の余白を詰める（行に付ける）。Mac の一覧の行の余白はもともと狭いので、今までどおり少しだけ空ける
    @ViewBuilder func compactRow() -> some View {
        #if os(iOS)
        listRowInsets(.vertical, AppList.rowVerticalInset)
        #else
        padding(.vertical, 4)
        #endif
    }
}
