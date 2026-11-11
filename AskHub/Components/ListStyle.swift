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

    /// Mac の plain の一覧が、行と見出しの中身の左右に自分で足す余白。札の中の文字を iOS と同じ位置にそろえるため、行の余白から引く
    #if os(macOS)
    static let platformRowInset: CGFloat = 8
    #else
    static let platformRowInset: CGFloat = 0
    #endif

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

/// 一覧のセクション。札を自分で描いて角の丸みを決める（標準の insetGrouped の角は小さくできず、Mac の一覧には札の形が無いため）。
/// 中の行を順に見て、最初と最後の行の角だけを丸める。Mac の一覧の列（選ぶ側）は標準の Section のまま（`compactList(selectable:)`）
struct CardSection<Content: View, Header: View, Footer: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    @Environment(\.drawsCardSections) private var drawsCards
    /// このセクションの行の id の頭。Mac の一覧は行をセクションをまたいだ id で見分けるので、
    /// `Group(subviews:)` の id だけだと、ほかのセクションの行と取り違えて同じ中身を出す
    @State private var sectionID = UUID()

    var body: some View {
        // 見出しと注記は、札の中の行の文字の先頭にそろえる（標準の insetGrouped と同じ並び）
        let side = AppList.sideMargin + AppList.rowSideInset
        if drawsCards {
            Section {
                Group(subviews: content) { rows in
                    let items = rows.enumerated().map { CardRowItem(section: sectionID, index: $0.offset, row: $0.element) }
                    ForEach(items) { item in
                        item.row.cardRow(CardRowPosition(index: item.index, count: items.count))
                    }
                }
                #if os(macOS)
                footerRow(leading: side - AppList.platformRowInset)
                #endif
            } header: {
                cardHeader(side: side)
            } footer: {
                #if os(iOS)
                footer.listRowInsets(.horizontal, side)
                #endif
            }
            .listSectionSeparator(.hidden)
        } else {
            Section {
                content
                #if os(macOS)
                footerRow(leading: nil)
                #endif
            } header: {
                header
            } footer: {
                #if os(iOS)
                footer
                #endif
            }
        }
    }

    @ViewBuilder private func cardHeader(side: CGFloat) -> some View {
        #if os(macOS)
        // Mac の plain の一覧にはセクションの間が無いので、見出しの無いセクションも前の札から離す
        if Header.self == EmptyView.self {
            Color.clear.frame(height: 2)
        } else {
            // Mac の見出しには listRowInsets が効かないので、札の中の行の文字の先頭まで寄せる
            header.padding(.leading, side - AppList.platformRowInset)
        }
        #else
        header.listRowInsets(.horizontal, side)
        #endif
    }

    #if os(macOS)
    /// Mac の一覧の注記は Section の footer に置くと 1 行で切れるので、札の外の行として置いて折り返す
    @ViewBuilder private func footerRow(leading: CGFloat?) -> some View {
        if Footer.self != EmptyView.self {
            footer
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(leading.map { EdgeInsets(top: 2, leading: $0, bottom: 10, trailing: $0) })
        }
    }
    #endif
}

/// 札の中の 1 行と、その id（セクションの id と、セクションの中の行の id を合わせる）
private struct CardRowItem: Identifiable {
    struct Key: Hashable {
        let section: UUID
        let row: Subview.ID
    }

    let section: UUID
    let index: Int
    let row: Subview

    var id: Key {
        Key(section: section, row: row.id)
    }
}

extension EnvironmentValues {
    /// CardSection が札を描くか。Mac の一覧の列（選ぶ側）では描かない
    @Entry var drawsCardSections = true
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
        .fill(Self.fill)
        #if os(macOS)
        // Mac の一覧の区切り線は行の中身の幅で切れて長さがまちまちになり、最後の行の下にも出るので、札の中に自分で引く
        .overlay(alignment: .top) {
            if !position.isFirst {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .padding(.leading, AppList.rowSideInset)
            }
        }
        #endif
        .padding(.horizontal, AppList.sideMargin)
    }

    /// 札の地の色。iOS の標準の一覧の札と同じ（ライトは白、ダークは少し明るい灰色）
    #if os(iOS)
    private static let fill = Color(uiColor: .secondarySystemGroupedBackground)
    #else
    private static let fill = Color(nsColor: .controlBackgroundColor)
    #endif
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

    /// 一覧の余白を詰める（List に付ける）。札を CardSection で描くので、iOS では角の無い grouped、Mac では素の plain にする。
    /// Mac の一覧の列（選ぶ側。`selectable`）は、選んだ行の濃い背景が札と重ならないよう、標準の一覧のまま札を描かない
    @ViewBuilder func compactList(selectable: Bool = false) -> some View {
        #if os(iOS)
        listStyle(.grouped)
            .listSectionSpacing(AppList.sectionSpacing)
            .environment(\.defaultMinListRowHeight, 44)
        #else
        if selectable {
            environment(\.drawsCardSections, false)
        } else {
            listStyle(.plain)
        }
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

    /// 札の中の 1 行にする（地・余白・区切り線の端）。CardSection が行ごとに付ける
    fileprivate func cardRow(_ position: CardRowPosition) -> some View {
        let side = AppList.sideMargin + AppList.rowSideInset - AppList.platformRowInset
        return listRowBackground(CardRowBackground(position: position))
            .listRowInsets(EdgeInsets(top: AppList.rowVerticalInset, leading: side, bottom: AppList.rowVerticalInset, trailing: side))
            #if os(iOS)
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
            #else
            .listRowSeparator(.hidden)
            #endif
    }
}
