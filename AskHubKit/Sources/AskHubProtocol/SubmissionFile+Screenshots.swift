import Foundation

// `SubmissionFile` の、App Store のスクショ（`docs/renewal/release.md` の「スクショ」）

extension SubmissionFile {
    /// スクショを撮り直せないわけ（`retakeScreenshots`）。撮り直せるなら nil。審査に出した後・UI テストで撮っている途中・
    /// 頼んだ撮り直しを始める前は撮り直せない
    public var retakeProblem: String? {
        if origin != .askhub { return "AskHub で始めたリリースだけ、スクショを撮り直せる" }
        if isEnded { return "\(version) のリリースはもう終わっている" }
        if submit != nil || isSubmitting || hasReviewInFlight { return "\(version) は審査に出した後なので、スクショを撮り直せない" }
        guard let shots = screenshots else { return "\(version) のスクショはまだ撮り始めていない" }
        if shots.state == .notConfigured { return "スクショの撮り方の設定（build.storeScreenshots）が無い" }
        if shots.state == .capturing, shots.run == nil, shots.library == nil {
            return "UI テストでスクショを撮っている途中。撮り終えてから撮り直す"
        }
        if shots.awaitsRetake { return "スクショの撮り直しをもう頼んでいる" }
        return nil
    }

    /// 撮影の様子
    public enum ScreenshotState: String, Codable, Sendable, CaseIterable {
        /// 撮っている（終わるまで審査に出す準備はそろわない）
        case capturing
        /// 撮って App Store Connect のものと比べた
        case captured
        /// 撮れなかった（`failure` に理由。スクショを変えずに審査に出せる）
        case failed
        /// リポジトリに撮り方（`build.storeScreenshots`）が無い（撮らない）
        case notConfigured

        /// 撮影が終わった（審査に出す準備として、どれでもよい）
        public var isSettled: Bool { self != .capturing }
    }

    /// 変わった所（画像の幅・高さに対する割合。0〜1）
    public struct ChangedArea: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var isValid: Bool {
            let inside = x + width <= 1.0001 && y + height <= 1.0001
            return [x, y, width, height].allSatisfy { (0...1).contains($0) } && width > 0 && height > 0 && inside
        }
    }

    /// 1 枚のスクショ（組の中の位置ごと）
    public struct Shot: Codable, Hashable, Sendable {
        /// App Store での位置（1 から）
        public var index: Int
        /// テストが付けた添付の名前（`01-ホーム` など）
        public var name: String
        /// 前回の App Store のものと違う（新しく足した位置も）
        public var changed: Bool
        /// 撮った画像の見本の状態リポジトリのパス（`StatePath.storeScreenshot`）。差のある画面だけ
        public var preview: String?
        /// 前回の App Store の画像の URL（App Store Connect の CDN）。無ければ新しく足した位置
        public var before: String?
        /// 変わった所。差が無い・全体が違う（大きさが違うなど）ときは nil
        public var area: ChangedArea?
        /// App Store Connect のライブラリが受け付けなかったわけ（取り込みに失敗した・終わらない）。この画面は前のままにするしかない
        public var rejected: String?

        public init(
            index: Int,
            name: String,
            changed: Bool,
            preview: String? = nil,
            before: String? = nil,
            area: ChangedArea? = nil,
            rejected: String? = nil
        ) {
            self.index = index
            self.name = name
            self.changed = changed
            self.preview = preview
            self.before = before
            self.area = area
            self.rejected = rejected
        }
    }

    /// 1 つの組（表示サイズ・言語）
    public struct ScreenshotSet: Codable, Hashable, Sendable {
        /// App Store Connect の表示サイズ（App Asset Library の配置グループ。`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` など）
        public var displayType: String
        /// App Store Connect の言語
        public var locale: String
        /// 撮ったスクショ（位置の順）
        public var shots: [Shot]
        /// 前回の App Store の組にあって、撮ったものより後ろの位置の数（審査に出すときに消す）
        public var removed: Int

        public init(displayType: String, locale: String, shots: [Shot], removed: Int = 0) {
            self.displayType = displayType
            self.locale = locale
            self.shots = shots
            self.removed = removed
        }

        /// 前回の App Store のものから変わった
        public var isChanged: Bool { removed > 0 || shots.contains(where: \.changed) }
    }

    /// App Store Connect にあるが撮らなかった表示サイズ
    public struct SkippedDisplayType: Codable, Hashable, Sendable {
        public var displayType: String
        public var reason: String

        public init(displayType: String, reason: String) {
            self.displayType = displayType
            self.reason = reason
        }
    }

    /// 撮影のワークフローの実行（`capture: actions`。`docs/renewal/store-screenshots.md` の「撮影の起動と見張り」）
    public typealias CaptureRun = WorkflowRunRecord

    /// 撮って比べた画像を、App Store Connect のライブラリに先に上げた様子（`docs/renewal/store-screenshots.md` の「先に上げておく」）。
    /// 配置はしない（審査に出すときに置く）。すべて置ける状態になる（か受け付けられない）まで、撮影は決着しない
    public struct LibraryUpload: Codable, Equatable, Sendable {
        /// 上げた画像の数（同じ画像は 1 つと数える）
        public var total: Int
        /// 処理を終え、置ける画像の数
        public var ready: Int
        /// 上げ終えた時刻（取り込みを打ち切る時間を数える）
        public var sentAt: Timestamp

        public init(total: Int, ready: Int = 0, sentAt: Timestamp) {
            self.total = total
            self.ready = ready
            self.sentAt = sentAt
        }

        var problems: [String] {
            total >= 0 && (0...max(total, 0)).contains(ready) ? [] : ["screenshots の library の ready は 0〜total"]
        }
    }

    /// 人が頼んだスクショの撮り直し（`retakeScreenshots`）。司令塔が撮り直しを始めたら `startedAt` を付ける
    public struct Retake: Codable, Equatable, Sendable {
        /// 撮り直す表示サイズ（配置グループ）。空ならすべて
        public var displayTypes: [String]
        /// 撮り直す言語（App Store Connect の言語）。空ならすべて
        public var locales: [String]
        public var approval: IntentReference
        public var at: Timestamp
        /// 撮り直しを始めた時刻。まだなら nil（その間は審査に出す準備をそろえない）
        public var startedAt: Timestamp?
        /// 一部だけ撮り直すとき、引き継ぐ組を撮ったコミット（元の画像をこのコミットの置き場所から写す）
        public var from: String?

        public init(
            displayTypes: [String] = [],
            locales: [String] = [],
            approval: IntentReference,
            at: Timestamp,
            startedAt: Timestamp? = nil,
            from: String? = nil
        ) {
            self.displayTypes = displayTypes
            self.locales = locales
            self.approval = approval
            self.at = at
            self.startedAt = startedAt
            self.from = from
        }

        /// 一部の組だけを撮り直す
        public var isPartial: Bool { !displayTypes.isEmpty || !locales.isEmpty }

        /// 撮り直す組か
        public func covers(displayType: String, locale: String) -> Bool {
            (displayTypes.isEmpty || displayTypes.contains(displayType)) && (locales.isEmpty || locales.contains(locale))
        }
    }

    /// App Store のスクショを撮って比べた結果
    public struct StoreScreenshots: Codable, Equatable, Sendable {
        public var state: ScreenshotState
        /// 撮った release ブランチのコミット
        public var commit: String?
        public var startedAt: Timestamp
        public var finishedAt: Timestamp?
        /// 撮って比べた組（差の無い組も持つ）
        public var sets: [ScreenshotSet]
        public var skipped: [SkippedDisplayType]
        /// 撮れなかった理由（`failed` のとき。`notConfigured` のときは、撮らなかったわけがあれば）
        public var failure: String?
        /// 撮影のワークフローの実行（`capture: actions` のときだけ）
        public var run: CaptureRun?
        /// App Store Connect のライブラリに先に上げた様子（上げている間・取り込みを待つ間。撮影は `capturing` のまま）
        public var library: LibraryUpload?
        /// 人が頼んだ撮り直し（受け付けた頼みと、撮り直している・撮り直した組）
        public var retake: Retake?

        /// 撮り直しを頼まれ、まだ始めていない
        public var awaitsRetake: Bool { retake != nil && retake?.startedAt == nil }

        public init(
            state: ScreenshotState,
            commit: String? = nil,
            startedAt: Timestamp,
            finishedAt: Timestamp? = nil,
            sets: [ScreenshotSet] = [],
            skipped: [SkippedDisplayType] = [],
            failure: String? = nil,
            run: CaptureRun? = nil,
            library: LibraryUpload? = nil,
            retake: Retake? = nil
        ) {
            self.state = state
            self.commit = commit
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.sets = sets
            self.skipped = skipped
            self.failure = failure
            self.run = run
            self.library = library
            self.retake = retake
        }

        /// 合わない点
        var problems: [String] {
            var problems: [String] = []
            problems += run?.problems(label: "screenshots の run") ?? []
            problems += library?.problems ?? []
            if let retake {
                let shaped = retake.displayTypes.allSatisfy(StoreScreenshotSettings.isDisplayType)
                    && retake.locales.allSatisfy(LocalizedText.isLocale)
                if !shaped || retake.from.map({ !ReleaseFile.isCommit($0) }) == true {
                    problems.append("screenshots の retake の displayTypes・locales・from の形が違う")
                }
            }
            let rejected = sets.flatMap(\.shots).compactMap(\.rejected)
            if rejected.contains(where: { $0.isEmpty || $0.count > 1000 }) { problems.append("screenshots の rejected は 1〜1,000 文字") }
            if commit.map({ !ReleaseFile.isCommit($0) }) ?? false { problems.append("screenshots の commit が 40 桁の 16 進でない") }
            if state == .failed ? failure == nil : (failure != nil && state != .notConfigured) {
                problems.append("screenshots の failure は、failed のときは持ち、captured・capturing のときは持たない")
            }
            if failure?.isEmpty == true { problems.append("screenshots の failure が空") }
            let keys = sets.map { "\($0.displayType)/\($0.locale)" }
            if Set(keys).count != keys.count { problems.append("screenshots の組が重複している") }
            for set in sets {
                if !StoreScreenshotSettings.isDisplayType(set.displayType) || !LocalizedText.isLocale(set.locale) {
                    problems.append("screenshots の組の displayType・locale の形が違う")
                }
                let indices = set.shots.map(\.index)
                if indices != Array(1..<(indices.count + 1)) || set.shots.count > StoreScreenshotSettings.maximumShots {
                    let limit = StoreScreenshotSettings.maximumShots
                    problems.append("screenshots の \(set.displayType)/\(set.locale) の位置は 1 から順に \(limit) 枚まで")
                }
                if set.removed < 0 { problems.append("screenshots の removed は 0 以上") }
                if set.shots.contains(where: { ($0.changed != ($0.preview != nil)) || ($0.area.map { !$0.isValid } ?? false) }) {
                    problems.append("screenshots の preview は差のある画面だけが持ち、area は 0〜1 の割合")
                }
            }
            return problems
        }
    }

    /// 審査に出すスクショの 1 枚の位置
    public struct ShotReference: Codable, Hashable, Sendable {
        public var displayType: String
        public var locale: String
        public var index: Int

        public init(displayType: String, locale: String, index: Int) {
            self.displayType = displayType
            self.locale = locale
            self.index = index
        }
    }

    /// 人が確かめたスクショ。差のある画面のうち、`keep` に挙げたものは前回の App Store のままにし、ほかは撮ったものに替える
    public struct ScreenshotDecision: Codable, Equatable, Sendable {
        /// 撮った release ブランチのコミット（人が見た撮影）
        public var commit: String
        /// 前のままにする画面
        public var keep: [ShotReference]

        public init(commit: String, keep: [ShotReference] = []) {
            self.commit = commit
            self.keep = keep
        }

        /// 合わない点
        public var problems: [String] {
            var problems: [String] = []
            if !ReleaseFile.isCommit(commit) { problems.append("screenshots の commit が 40 桁の 16 進でない") }
            if Set(keep).count != keep.count { problems.append("screenshots の keep が重複している") }
            if keep.count > 2_000 { problems.append("screenshots の keep が多すぎる") }
            if keep.contains(where: { !StoreScreenshotSettings.isDisplayType($0.displayType) || !LocalizedText.isLocale($0.locale) }) {
                problems.append("screenshots の keep の displayType・locale の形が違う")
            }
            if keep.contains(where: { !(1...StoreScreenshotSettings.maximumShots).contains($0.index) }) {
                problems.append("screenshots の keep の index は 1〜\(StoreScreenshotSettings.maximumShots)")
            }
            return problems
        }
    }
}
