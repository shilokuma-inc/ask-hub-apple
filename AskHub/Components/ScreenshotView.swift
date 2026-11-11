import ImageIO
import SwiftUI

/// 判断のカードの Before / After のスクショ
struct ScreenshotView: View {
    let screenshot: Screenshot?

    var body: some View {
        Group {
            switch screenshot {
            case .stored(let path):
                // パスが変わったら、前の画像を残さずに読み直す
                StoredScreenshotImage(path: path)
                    .id(path)

            case .demo(let screen):
                DemoScreenView(screen: screen)

            case nil:
                ContentUnavailableView("画面の変化はありません", systemImage: "rectangle.dashed")
                    .appFont(.caption)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
}

/// ワーカーが撮って状態リポジトリに置いたスクショ。読むまでは待ちの表示、読めなければそのわけと読み直すボタンを出す
struct StoredScreenshotImage: View {
    let path: String
    @Environment(ClientStore.self) private var store
    @State private var image: CGImage?
    @State private var failure: String?
    /// 読み直すたびに増やす（`task` を流し直す）
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else if let failure {
                ContentUnavailableView {
                    Label("スクショを読めない", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("もう一度読む") { attempt += 1 }
                }
                .appFont(.caption)
            } else {
                ProgressView()
            }
        }
        .task(id: attempt) {
            failure = nil
            switch await store.screenshot(at: path) {
            case let .success(data):
                image = Self.image(from: data)
                failure = image == nil ? "画像の形が違う" : nil
            case let .failure(error):
                failure = error.message
            }
        }
    }

    static func image(from data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}

/// Before / After を横に並べる。`zoomable` なら、押すと大きく開く
struct BeforeAfterView: View {
    let before: Screenshot?
    let after: Screenshot?
    var zoomable = false
    @State private var zoomed: ZoomedScreenshot?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column("Before", before)
            column("After", after)
        }
        .sheet(item: $zoomed) { zoomed in
            ScreenshotZoomSheet(title: zoomed.title, screenshot: zoomed.screenshot)
        }
    }

    @ViewBuilder
    private func column(_ title: String, _ screenshot: Screenshot?) -> some View {
        let content = VStack(spacing: 4) {
            Text(title)
                .appFont(.caption2, weight: .semibold)
                .foregroundStyle(.secondary)
            ScreenshotView(screenshot: screenshot)
                .accessibilityLabel("\(title) のスクショ")
        }
        .frame(maxWidth: .infinity)
        if zoomable, let screenshot {
            Button {
                zoomed = ZoomedScreenshot(title: title, screenshot: screenshot)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint("大きく開く")
        } else {
            content
        }
    }
}

/// 大きく開くスクショ
struct ZoomedScreenshot: Identifiable {
    let title: String
    let screenshot: Screenshot
    var id: String { title }
}

/// スクショを大きく開くシート
struct ScreenshotZoomSheet: View {
    let title: String
    let screenshot: Screenshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                ScreenshotView(screenshot: screenshot)
                    .frame(maxWidth: 520)
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .sheetSize(.page)
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
