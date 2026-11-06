import SwiftUI

/// 一覧の余白と行の文字。標準の List はセクションの間と行の上下の余白が広く、一画面に入る行が少ないので詰める
/// （ユーザーの要望。2026-11-03）。行の当たりは HIG の 44pt を下回らない
enum AppList {
    /// 行の上下の余白（標準はおよそ 11pt）
    static let rowVerticalInset: CGFloat = 8
    /// セクションの間（標準の `.default` より狭い）
    static let sectionSpacing: CGFloat = 16
    /// 札（セクション）の左右の外側の余白と、札の中の行の左右の余白
    static let sideMargin: CGFloat = 16
    static let rowSideInset: CGFloat = 16

    /// 札の角の半径。iOS 26 の標準の一覧（insetGrouped）は約 24pt で丸すぎるので、カードの選択肢の行と同じ 12pt にする
    /// （ユーザーが 24・16・12・10・8pt を見比べて決めた。2026-11-03）
    static let cornerRadius: CGFloat = 12
}

/// 札の中の行の位置（最初と最後の行だけ角を丸める）
struct CardRowPosition: Equatable {
    var isFirst: Bool
    var isLast: Bool

    init(index: Int, count: Int) {
        isFirst = index == 0
        isLast = index == count - 1
    }
}

/// 一覧のセクション。iOS では札を自分で描いて角の丸みを決める（標準の insetGrouped の角は小さくできないため）。
/// 中の行を順に見て、最初と最後の行の角だけを丸める。Mac は標準の Section のまま
struct CardSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    var body: some View {
        #if os(iOS)
        // 見出しと注記は、札の中の行の文字の先頭にそろえる（標準の insetGrouped と同じ並び）
        let side = AppList.sideMargin + AppList.rowSideInset
        Section {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row.cardRow(CardRowPosition(index: index, count: rows.count))
                }
            }
        } header: {
            header.listRowInsets(.horizontal, side)
        } footer: {
            footer.listRowInsets(.horizontal, side)
        }
        .listSectionSeparator(.hidden)
        #else
        Section {
            content
        } header: {
            header
        } footer: {
            footer
        }
        #endif
    }
}

extension CardSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension CardSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension CardSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension CardSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

#if os(iOS)
/// 札の中の 1 行の地。最初の行は上の角、最後の行は下の角を丸める
private struct CardRowBackground: View {
    let position: CardRowPosition

    var body: some View {
        let top = position.isFirst ? AppList.cornerRadius : 0
        let bottom = position.isLast ? AppList.cornerRadius : 0
        UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
        .fill(Color(uiColor: .secondarySystemGroupedBackground))
        .padding(.horizontal, AppList.sideMargin)
    }
}
#endif

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

    /// 一覧の余白を詰める（List に付ける）。iOS では札を CardSection で描くので、角の無い grouped にする。
    /// Mac の一覧はもともと詰まっていて、セクションの間の指定も無いので、そのままにする
    @ViewBuilder func compactList() -> some View {
        #if os(iOS)
        listStyle(.grouped)
            .listSectionSpacing(AppList.sectionSpacing)
            .environment(\.defaultMinListRowHeight, 44)
        #else
        self
        #endif
    }

    /// Mac の一覧の行の上下の余白（行の部品に付ける）。iOS の行の余白は CardSection が行に付ける
    @ViewBuilder func compactRow() -> some View {
        #if os(iOS)
        self
        #else
        padding(.vertical, 4)
        #endif
    }

    #if os(iOS)
    /// 札の中の 1 行にする（地・余白・区切り線の端）。CardSection が行ごとに付ける
    fileprivate func cardRow(_ position: CardRowPosition) -> some View {
        let side = AppList.sideMargin + AppList.rowSideInset
        return listRowBackground(CardRowBackground(position: position))
            .listRowInsets(EdgeInsets(top: AppList.rowVerticalInset, leading: side, bottom: AppList.rowVerticalInset, trailing: side))
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
    }
    #endif
}
