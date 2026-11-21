import Foundation

// `SubmissionFile` の、App Store のスクショ（`docs/renewal/release.md` の「スクショ」）

extension SubmissionFile {
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

        public init(index: Int, name: String, changed: Bool, preview: String? = nil, before: String? = nil, area: ChangedArea? = nil) {
            self.index = index
            self.name = name
            self.changed = changed
            self.preview = preview
            self.before = before
            self.area = area
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
    public struct CaptureRun: Codable, Equatable, Sendable {
        /// run の id。起動の応答か、起動した後の一覧で分かる。分かるまでは nil
        public var id: Int?
        /// run の画面（`html_url`）
        public var url: String?
        /// 起動を送った時刻（送る前に書く。id が分からないまま時間がたてば送り直す）
        public var dispatchedAt: Timestamp
        /// GitHub の run の様子（`queued`・`in_progress`・`completed` など）。まだ読んでいなければ nil
        public var status: String?
        /// 終わった run の結論（`success`・`failure`・`cancelled` など）
        public var conclusion: String?
        /// 起動の前からあった、ブランチの `workflow_dispatch` の run の最大の id（無ければ 0）。id の分からない run を一覧から探すとき、
        /// これより新しい run だけを候補にする（起動の前に人が起動した run を取り違えない）
        public var after: Int?

        public init(
            id: Int? = nil,
            url: String? = nil,
            dispatchedAt: Timestamp,
            status: String? = nil,
            conclusion: String? = nil,
            after: Int? = nil
        ) {
            self.id = id
            self.url = url
            self.dispatchedAt = dispatchedAt
            self.status = status
            self.conclusion = conclusion
            self.after = after
        }

        /// 終わった
        public var isCompleted: Bool { status == "completed" }

        var problems: [String] {
            var problems: [String] = []
            if let id, id <= 0 { problems.append("screenshots の run の id は 1 以上") }
            if let after, after < 0 { problems.append("screenshots の run の after は 0 以上") }
            if let url, !url.hasPrefix("https://github.com/") || url.count > 400 { problems.append("screenshots の run の url は GitHub の画面") }
            let words = [status, conclusion].compactMap(\.self)
            if !words.allSatisfy({ $0.wholeMatch(of: #/[a-z_]{1,40}/#) != nil }) {
                problems.append("screenshots の run の status・conclusion の形が違う")
            }
            return problems
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
        /// 撮れなかった理由（`failed` のとき）
        public var failure: String?
        /// 撮影のワークフローの実行（`capture: actions` のときだけ）
        public var run: CaptureRun?

        public init(
            state: ScreenshotState,
            commit: String? = nil,
            startedAt: Timestamp,
            finishedAt: Timestamp? = nil,
            sets: [ScreenshotSet] = [],
            skipped: [SkippedDisplayType] = [],
            failure: String? = nil,
            run: CaptureRun? = nil
        ) {
            self.state = state
            self.commit = commit
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.sets = sets
            self.skipped = skipped
            self.failure = failure
            self.run = run
        }

        /// 合わない点
        var problems: [String] {
            var problems: [String] = []
            problems += run?.problems ?? []
            if commit.map({ !ReleaseFile.isCommit($0) }) ?? false { problems.append("screenshots の commit が 40 桁の 16 進でない") }
            if (state == .failed) != (failure != nil) { problems.append("screenshots の failure は、failed のときだけ持つ") }
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
