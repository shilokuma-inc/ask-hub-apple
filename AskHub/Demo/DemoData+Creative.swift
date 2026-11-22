import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - クリエイティブアセット（App Store のヘッダー・検索結果の画像）

extension DemoData {
    static let creativeRepository = "demo-studio/habit-ios"

    /// 習慣ログの案 2 を確かめる番（前の案 1 と見比べられる）
    func creatives() -> [CreativeOverview] {
        let repo = Self.creativeRepository
        func images(_ revision: Int) -> [CreativeOverview.Image] {
            ["ja", "en-US"].flatMap { locale in
                CreativeOverview.Kind.allCases.map { kind in
                    CreativeOverview.Image(
                        locale: locale,
                        kind: kind,
                        screenshot: .stored("repos/\(repo)/creative/\(revision)/\(locale)/\(kind.rawValue).b64"),
                        problems: revision == 2 && locale == "en-US" && kind == .productPageHeader
                            ? [.init(code: "text-overflow", message: "header.title が 2 行・幅 1646px に収まりません（最小の 80px でも）")]
                            : []
                    )
                }
            }
        }
        return [
            CreativeOverview(
                repositoryID: repo,
                draft: .init(
                    revision: 2,
                    state: .rendered,
                    comment: "見出しをもっと短く。背景をアプリの緑に近づけて",
                    requestedAt: ago(minutes: 50),
                    reason: "毎日続けられることを見出しにし、背景をアプリのアクセントカラーの緑に寄せました。検索結果は記録の画面を手前に置きました",
                    titles: ["ja": "今日の習慣を、ひと押しで", "en-US": "Build habits with one tap"],
                    images: images(2),
                    runURL: URL(string: "https://github.com/\(repo)/actions/runs/45100000201")
                ),
                previous: .init(revision: 1, images: images(1)),
                updatedAt: ago(minutes: 18)
            )
        ]
    }

    /// デモの見本の画像（状態リポジトリの代わり）。案の版で色を変え、安全領域に見出しの帯を描く
    static func creativePreview(at path: String) -> Data? {
        let parts = path.split(separator: "/")
        guard parts.count == 7, parts[3] == "creative", let revision = Int(parts[4]) else { return nil }
        let kind = CreativeOverview.Kind(rawValue: String(parts[6].dropLast(4))) ?? .productPageHeader
        let width = 600
        let height = Int((CGFloat(width) / kind.aspectRatio).rounded())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let background = revision == 2
            ? CGColor(red: 0.08, green: 0.22, blue: 0.16, alpha: 1)
            : CGColor(red: 0.1, green: 0.1, blue: 0.24, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let safe = kind.safeArea
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        // 見出しの帯（安全領域の上のほう）と、端末の形
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        let title = CGRect(
            x: safe.minX * size.width, y: size.height * (1 - safe.minY) - 14, width: safe.width * size.width * 0.8, height: 10
        )
        context.fill(title)
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1))
        let phoneWidth = size.width * 0.14
        let phoneX = size.width * (kind == .productPageHeader ? 0.43 : 0.62)
        let phone = CGRect(x: phoneX, y: size.height * 0.05, width: phoneWidth, height: phoneWidth * 2.1)
        context.addPath(CGPath(roundedRect: phone, cornerWidth: 8, cornerHeight: 8, transform: nil))
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension DemoClientService {
    /// App Store の準備とクリエイティブアセットの意図を、デモの状態に当てる
    func applyStoreAssetIntent(_ intent: HumanIntent) {
        switch intent {
        case .draftCreativeAssets, .approveCreativeAssets:
            applyCreativeIntent(intent)
        default:
            applyAppStoreSetupIntent(intent)
        }
    }

    /// デモの見本の画像（クリエイティブアセットだけ。ほかの見本はデモに無い）
    func screenshot(at path: String) async throws -> Data {
        guard let data = DemoData.creativePreview(at: path) else { throw ClientServiceError(message: "このデータの元にはスクショが無い") }
        return data
    }

    /// クリエイティブアセットの意図を、デモの状態に当てる（頼んだら次の案を書いている途中、承認したら承認済み）
    func applyCreativeIntent(_ intent: HumanIntent) {
        let date = now()
        switch intent {
        case let .draftCreativeAssets(repositoryID, revision, comment):
            var creative = state.creatives.first { $0.repositoryID == repositoryID }
                ?? CreativeOverview(repositoryID: repositoryID, updatedAt: date)
            if let old = creative.draft, old.state == .rendered { creative.previous = .init(revision: old.revision, images: old.images) }
            creative.draft = .init(revision: revision + 1, state: .drafting, comment: comment, requestedAt: date)
            creative.updatedAt = date
            state.creatives.removeAll { $0.repositoryID == repositoryID }
            state.creatives.append(creative)

        case let .approveCreativeAssets(repositoryID, revision):
            guard let index = state.creatives.firstIndex(where: { $0.repositoryID == repositoryID }),
                  let draft = state.creatives[index].draft, draft.revision == revision else { return }
            state.creatives[index].approved = .init(revision: revision, images: draft.images, approvedAt: date)
            state.creatives[index].updatedAt = date

        default:
            break
        }
    }
}
