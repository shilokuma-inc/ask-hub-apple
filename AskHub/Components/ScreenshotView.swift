import SwiftUI

/// 判断のカードの Before / After のスクショ
struct ScreenshotView: View {
    let screenshot: Screenshot?

    var body: some View {
        Group {
            switch screenshot {
            case .image(let url):
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }

            case .demo(let screen):
                DemoScreenView(screen: screen)

            case nil:
                ContentUnavailableView("画面の変化はありません", systemImage: "rectangle.dashed")
                    .font(.caption)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
}

/// Before / After を横に並べる
struct BeforeAfterView: View {
    let before: Screenshot?
    let after: Screenshot?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column("Before", before)
            column("After", after)
        }
    }

    private func column(_ title: String, _ screenshot: Screenshot?) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScreenshotView(screenshot: screenshot)
                .accessibilityLabel("\(title) のスクショ")
        }
        .frame(maxWidth: .infinity)
    }
}

/// デモのデータで描く簡単な画面の絵。変わったところを色の枠で示す
struct DemoScreenView: View {
    let screen: DemoScreen

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(screen.title)
                    .font(.system(size: 9, weight: .bold))
                Spacer()
                if let item = screen.toolbarItem {
                    Text(item)
                        .font(.system(size: 7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(highlight(screen.toolbarItemHighlighted))
                }
            }
            ForEach(Array(screen.elements.enumerated()), id: \.offset) { _, element in
                elementView(element)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder private func elementView(_ element: DemoScreen.Element) -> some View {
        switch element {
        case .search(let highlighted):
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass")
                Text("検索")
            }
            .font(.system(size: 7))
            .foregroundStyle(.secondary)
            .padding(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: 4))
            .overlay(highlight(highlighted))

        case let .section(title, highlighted):
            Text(title)
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .overlay(highlight(highlighted))

        case let .row(title, detail, highlighted):
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 8))
                if let detail {
                    Text(detail)
                        .font(.system(size: 6))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(highlight(highlighted))
        }
    }

    private func highlight(_ isOn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(isOn ? Theme.accent : .clear, lineWidth: 1)
            .padding(-2)
    }
}

#Preview("Before / After") {
    BeforeAfterView(
        before: .demo(DemoData.bookList(search: false, highlightSearch: false)),
        after: .demo(DemoData.bookList(search: true, highlightSearch: true))
    )
    .frame(width: 260)
    .padding()
}
