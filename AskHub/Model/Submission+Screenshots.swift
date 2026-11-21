import CoreGraphics
import Foundation

// `Submission` の、App Store のスクショ（画面用）

extension Submission {
    /// 撮影の様子
    enum ScreenshotState: Hashable {
        case capturing
        case captured
        /// 撮れなかった（スクショを変えずに審査に出せる）
        case failed(String)
        /// 撮り方が無い（撮らない）
        case notConfigured
    }

    /// App Store Connect にあるが撮らなかった表示サイズと、そのわけ
    struct SkippedDisplayType: Hashable, Identifiable {
        var displayType: String
        var reason: String

        var id: String { "\(displayType)/\(reason)" }
    }

    /// App Store のスクショを撮って比べた結果
    struct StoreScreenshots: Hashable {
        var state: ScreenshotState
        /// 撮った release ブランチのコミット（審査に出すときに、見た撮影に結びつける）
        var commit: String?
        var sets: [ScreenshotSet]
        var skipped: [SkippedDisplayType]

        /// 差のある組
        var changedSets: [ScreenshotSet] { sets.filter(\.isChanged) }
    }

    /// 1 つの組（表示サイズ・言語）
    struct ScreenshotSet: Hashable, Identifiable {
        var displayType: String
        var locale: String
        var shots: [Shot]
        /// 前回の組にあって、撮ったものより後ろの位置の数（審査に出すときに消す）
        var removed: Int

        var id: String { "\(displayType)/\(locale)" }
        var isChanged: Bool { removed > 0 || shots.contains(where: \.changed) }
        var changedShots: [Shot] { shots.filter(\.changed) }

        func key(_ shot: Shot) -> ShotKey {
            ShotKey(displayType: displayType, locale: locale, index: shot.index)
        }

        /// 例: iPhone 6.9 インチ・日本語（ja）
        var title: String {
            "\(Self.displayName(displayType))・\(Localized(locale: locale, text: "").localeName)"
        }

        /// App Store Connect の表示サイズ（App Asset Library の配置グループ）の呼び名。知らないものは配置グループのまま出す。
        /// 配置グループの名前は Apple のリファレンスデータで決まり、文書にあるのは 6.9 インチ（`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE`）だけなので、
        /// 頭の表示クラス（`AppAssetLibraryDisplayClass`）の名前で当てる
        static func displayName(_ displayType: String) -> String {
            let names = [
                ("IPHONE_DUO", "iPhone Duo"), ("IPHONE_DYNAMIC_ISLAND_LARGE", "iPhone 6.9 インチ"),
                ("IPHONE_DYNAMIC_ISLAND_MEDIUM", "iPhone 6.3 インチ"), ("IPHONE_FACE_ID_LARGE", "iPhone 6.5 インチ"),
                ("IPHONE_HOME_BUTTON_LARGE", "iPhone 5.5 インチ"), ("IPAD_13_", "iPad 13 インチ"), ("IPAD_129_", "iPad 12.9 インチ"),
                ("IPAD_11_", "iPad 11 インチ"), ("MAC_", "Mac"), ("VISION_PRO_", "Apple Vision Pro")
            ]
            return names.first { displayType.hasPrefix($0.0) }?.1 ?? displayType
        }
    }

    /// 1 枚のスクショ
    struct Shot: Hashable, Identifiable {
        /// App Store での位置（1 から）
        var index: Int
        /// テストが付けた名前
        var name: String
        var changed: Bool
        /// 前回の App Store の画像。無ければ新しく足した位置
        var before: Screenshot?
        /// 撮った画像の見本（差のある画面だけ）
        var after: Screenshot?
        /// 変わった所（画像に対する割合。左上が原点）
        var area: CGRect?

        var id: Int { index }
    }

    /// スクショの 1 枚の位置
    struct ShotKey: Hashable {
        var displayType: String
        var locale: String
        var index: Int
    }
}
