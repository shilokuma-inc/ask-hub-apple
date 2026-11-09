import Foundation

extension RepositoryFile {
    /// リポジトリのビルドの設定（`repo.json` の `build`。`docs/renewal/protocol.md` の「repo.json」）。
    /// 人が設定を入れる意図（`configureRepository`）で書き、ワーカーがビルドとテスト・子 PR・最終 PR で読む。無いリポジトリでは開始を断る
    public struct Build: Codable, Equatable, Sendable {
        public static let defaultBaseBranch = "develop"
        /// チェックの名前の長さの上限（Unicode のコードポイントの数）
        public static let maximumCheckNameLength = 200

        /// 作業ブランチの元で、最終 PR の向き先
        public var baseBranch: String
        /// ビルドとテストの設定（プロジェクト・スキーム・行き先・`testLight`・`testFull`）
        public var xcode: BuildSettings
        /// 子 PR で待つチェックの名前（REST の check run の `name`。再利用ワークフローのジョブは `build / build` の形）
        public var childChecks: [String]
        /// 最終 PR で待つチェックの名前
        public var finalChecks: [String]
        /// 指摘を Claude に渡してよいレビューの書き手（GitHub のアカウント。`coderabbitai[bot]` など）
        public var trustedReviewers: [String]
        /// 判断のカードのスクショの撮り方。無ければ撮らない
        public var screenshots: ScreenshotSettings?

        public init(
            baseBranch: String = Self.defaultBaseBranch,
            xcode: BuildSettings,
            childChecks: [String],
            finalChecks: [String],
            trustedReviewers: [String] = [],
            screenshots: ScreenshotSettings? = nil
        ) {
            self.baseBranch = baseBranch
            self.xcode = xcode
            self.childChecks = childChecks
            self.finalChecks = finalChecks
            self.trustedReviewers = trustedReviewers
            self.screenshots = screenshots
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            baseBranch = try container.decodeIfPresent(String.self, forKey: .baseBranch) ?? Self.defaultBaseBranch
            xcode = try container.decode(BuildSettings.self, forKey: .xcode)
            childChecks = try container.decode([String].self, forKey: .childChecks)
            finalChecks = try container.decode([String].self, forKey: .finalChecks)
            trustedReviewers = try container.decodeIfPresent([String].self, forKey: .trustedReviewers) ?? []
            screenshots = try container.decodeIfPresent(ScreenshotSettings.self, forKey: .screenshots)
        }

        /// 型だけでは表せない決まりに合わないところ（`xcode` の形は読むときに `BuildSettings` が確かめる）
        public var problems: [String] {
            var problems: [String] = []
            if !EpicFile.isBranchName(baseBranch) { problems.append("build.baseBranch の形が違う") }
            do {
                try xcode.validate()
            } catch {
                problems.append("build.xcode: \(error.description)")
            }
            problems += Self.checkProblems(childChecks, field: "childChecks") + Self.checkProblems(finalChecks, field: "finalChecks")
            if !trustedReviewers.allSatisfy(Self.isAccount) || Set(trustedReviewers).count != trustedReviewers.count {
                problems.append("build.trustedReviewers は GitHub のアカウント（重ならない）")
            }
            problems += screenshots?.problems ?? []
            return problems
        }

        /// 待つチェックは 1 つ以上（無いと、CI を待たずにマージしてしまう）。重ならず、空や制御文字を含まない
        private static func checkProblems(_ names: [String], field: String) -> [String] {
            let valid = names.allSatisfy { name in
                (1...maximumCheckNameLength).contains(name.unicodeScalars.count)
                    && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            }
            guard !names.isEmpty, valid, Set(names).count == names.count else {
                return ["build.\(field) は 1 つ以上の、重ならない空でない名前（\(maximumCheckNameLength) 文字まで・制御文字なし）"]
            }
            return []
        }

        /// GitHub のアカウント（英数字とハイフン。bot は末尾に `[bot]`）
        static func isAccount(_ text: String) -> Bool {
            text.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9-]{0,38}(\[bot\])?/#) != nil
        }
    }
}
