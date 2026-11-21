import AskHubBuild
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 撮った組を、配信中の版のスクショと比べる（UI テストと Actions の撮り方で共通。`docs/renewal/release.md` の「スクショ」）。
/// 差のある画面は、元の画像を常時オンの Mac に置き、見本（幅 600 の JPEG を base64 にした文字）を返す。見本は呼ぶ側が、
/// 撮影の終わりに 1 回のコミットでまとめて書く（`docs/renewal/store-screenshots.md` の「見本の書き方」）
struct StoreScreenshotComparer: Sendable {
    var store: any AppStoreConnectSubmitting
    var repo: RepositoryFullName
    var version: MarketingVersion
    /// 撮ったコミット（見本のパスに入れる）
    var commit: String
    /// 撮った元の画像のフォルダ（常時オンの Mac）
    var originals: URL

    /// 比べた組と、その見本（状態リポジトリのパス → base64 の文字）
    struct Compared {
        var set: SubmissionFile.ScreenshotSet
        var previews: [String: String]
    }

    /// 撮った組を、配信中の版の組（`current`。無ければ空で、すべて新しい画面）と比べる
    func compare(_ target: StoreScreenshotTarget, shots: [CapturedShot], current: [AppStoreScreenshot]) async throws -> Compared {
        var result: [SubmissionFile.Shot] = []
        var previews: [String: String] = [:]
        for (offset, shot) in shots.enumerated() {
            let index = offset + 1
            guard let after = try? Data(contentsOf: shot.file) else {
                throw ReleaseStepProblem("撮った画像（\(target.key) の \(index) 枚目）を読めない", needsHuman: false)
            }
            let before = offset < current.count ? current[offset] : nil
            var difference = ScreenshotDifference(changed: true)
            if let before {
                if before.checksum == AppStoreScreenshot.checksum(of: after) {
                    difference = ScreenshotDifference(changed: false)
                } else if let url = before.imageURL {
                    let old = try await call { () throws(AppStoreConnectError) in try await store.downloadScreenshot(url) }
                    difference = ScreenshotDiff.compare(before: old, after: after)
                }
            }
            let url = before?.imageURL?.absoluteString
            var entry = SubmissionFile.Shot(index: index, name: shot.name, changed: difference.changed, before: url)
            if difference.changed {
                entry.area = difference.area.map(Self.area)
                let (path, preview) = try keep(after, target: target, index: index)
                entry.preview = path
                previews[path] = preview
            }
            result.append(entry)
        }
        let set = SubmissionFile.ScreenshotSet(
            displayType: target.displayType, locale: target.locale, shots: result, removed: max(0, current.count - shots.count)
        )
        return Compared(set: set, previews: previews)
    }

    /// 差のある画面の元の画像を常時オンの Mac に置き、見本のパスと中身（base64 の文字）を返す
    private func keep(_ data: Data, target: StoreScreenshotTarget, index: Int) throws -> (path: String, preview: String) {
        let original = Self.original(in: originals, target: target, index: index)
        do {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: original, options: .atomic)
        } catch {
            throw ReleaseStepProblem("撮った画像を常時オンの Mac に置けない（\(error.localizedDescription)）", needsHuman: false)
        }
        guard let preview = ScreenshotDiff.preview(of: data) else {
            throw ReleaseStepProblem("撮った画像（\(target.key) の \(index) 枚目）の見本を作れない", needsHuman: false)
        }
        let path = StatePath.storeScreenshot(
            repo, version, commit: commit, shot: .init(displayType: target.displayType, locale: target.locale, index: index)
        )
        return (path, preview.base64EncodedString())
    }

    /// 見本をまとめて 1 回のコミットで書く
    static func writePreviews(
        _ previews: [String: String],
        of file: SubmissionFile,
        to store: any StateStore
    ) async throws {
        guard !previews.isEmpty else { return }
        do {
            try await store.writeTextFiles(previews, message: "\(file.repo) の \(file.version) のスクショの見本（\(previews.count) 枚）")
        } catch {
            throw ReleaseStepProblem("スクショの見本を状態リポジトリに置けない（\(error)）", needsHuman: false)
        }
    }

    /// 元の画像のファイル（`<originals>/<表示サイズ>/<言語>/<位置>.png`）
    static func original(in originals: URL, target: StoreScreenshotTarget, index: Int) -> URL {
        originals.appendingPathComponent(target.displayType).appendingPathComponent(target.locale).appendingPathComponent("\(index).png")
    }

    /// 変わった所（小数 4 桁）
    static func area(_ rect: CGRect) -> SubmissionFile.ChangedArea {
        func round(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        return .init(x: round(rect.minX), y: round(rect.minY), width: round(rect.width), height: round(rect.height))
    }

    private func call<Value>(_ body: () async throws(AppStoreConnectError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw ReleaseWatch.problem(error)
        }
    }
}
