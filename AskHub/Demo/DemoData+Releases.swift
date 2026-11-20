import Foundation

// MARK: - App Store で配信した版

extension DemoData {
    /// 配信した版（リポジトリの順、その中は新しい版から）。習慣ログの 1.2.0 はリリース文の確認を待ち、ほかは後作業が済んでいる
    func releases() -> [Release] {
        let habit = Self.repositoryID("habit-ios")
        let recipe = Self.repositoryID("recipe-apple")
        return [
            Release(
                repositoryID: recipe,
                version: "2.0.1",
                platforms: [.init(name: "iOS", build: "120"), .init(name: "macOS", build: "121")],
                detectedAt: ago(minutes: 60 * 24 * 9),
                updatedAt: ago(minutes: 60 * 24 * 9 - 40),
                commit: .init(sha: "7d2e91b04c5a6f3e8d1b2a9c0e4f5d6a7b8c9d0e", fromExistingTag: false),
                tagName: "v2.0.1",
                notes: .init(version: 1, previousTag: "v2.0.0", draft: Self.recipeNotes, confirmed: Self.recipeNotes),
                githubReleaseURL: URL(string: "https://github.com/\(recipe)/releases/tag/v2.0.1"),
                nextVersion: .init(version: "2.1.0", state: .merged, pullRequest: 188),
                promotionalText: .init(current: [
                    .init(locale: "ja", text: "Mac でも使えるようになりました。"),
                    .init(locale: "en-US", text: "")
                ])
            ),
            Release(
                repositoryID: habit,
                version: "1.2.0",
                platforms: [.init(name: "iOS", build: "58")],
                detectedAt: ago(minutes: 60 * 26),
                updatedAt: ago(minutes: 60 * 25),
                commit: .init(sha: "4f1c2a9e8b7d6c5f4e3d2c1b0a9f8e7d6c5b4a39", fromExistingTag: false),
                tagName: "v1.2.0",
                notes: .init(version: 1, previousTag: "v1.1.0", draft: Self.habitNotes),
                nextVersion: .init(version: "1.3.0", state: .merged, pullRequest: 214)
            ),
            Release(
                repositoryID: habit,
                version: "1.1.0",
                platforms: [.init(name: "iOS", build: "41")],
                detectedAt: ago(minutes: 60 * 24 * 30),
                updatedAt: ago(minutes: 60 * 24 * 30 - 50),
                commit: .init(sha: "0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1a", fromExistingTag: true),
                tagName: "v1.1.0",
                githubReleaseURL: URL(string: "https://github.com/\(habit)/releases/tag/v1.1.0"),
                nextVersion: .init(version: "1.2.0", state: .skipped)
            )
        ]
    }

    /// リリースを始めた版。レシピ帳の 2.1.0 は、準備がそろって審査に出すのを待っている
    func submissions() -> [Submission] {
        let recipe = Self.repositoryID("recipe-apple")
        var submission = Submission(
            repositoryID: recipe,
            version: "2.1.0",
            startedInAskHub: true,
            branch: "release/2.1.0",
            nextVersion: .init(version: "2.2.0", state: .merged, pullRequest: 203),
            builds: [.init(platform: "iOS", build: "131"), .init(platform: "macOS", build: "132")],
            drafts: [
                .init(locale: "ja", text: Self.recipeWhatsNewJapanese),
                .init(locale: "en-US", text: Self.recipeWhatsNewEnglish)
            ],
            listing: Self.recipeListing,
            appReview: .init(
                current: .init(notes: "ログインは不要です。レシピは右上の＋から足せます。", demoAccountRequired: false),
                draft: .init(notes: "ログインは不要です。レシピは右上の＋から足せます。レシピの画面の「人数」を変えると、材料の分量が変わります。"),
                reason: "人数に合わせた分量の計算は見つけにくいので、試し方を審査メモに足す案です"
            ),
            revision: 3,
            createdAt: ago(minutes: 60 * 3),
            updatedAt: ago(minutes: 25)
        )
        submission.awaitsSubmission = true
        submission.canAbandon = true
        return [submission]
    }

    /// レシピ帳の掲載文の案（人数に合わせた分量の計算を、日本語の説明文とキーワード・英語のキーワードに入れる）
    static let recipeListing = Submission.Listing(
        current: [
            .init(locale: "ja", values: [
                .description: "毎日のごはん作りを助けるレシピ帳です。写真付きでレシピを残し、買い物リストを作れます。",
                .keywords: "レシピ,料理,献立,買い物リスト",
                .promotionalText: "Mac でも使えるようになりました。"
            ]),
            .init(locale: "en-US", values: [
                .description: "A recipe book for everyday cooking. Save recipes with photos and build shopping lists.",
                .keywords: "recipe,cooking,meal plan,shopping list"
            ])
        ],
        drafts: [
            .init(locale: "ja", values: [
                .description: "毎日のごはん作りを助けるレシピ帳です。写真付きでレシピを残し、買い物リストを作れます。人数に合わせて材料の分量を自動で計算します。",
                .keywords: "レシピ,料理,献立,買い物リスト,分量"
            ]),
            .init(locale: "en-US", values: [.keywords: "recipe,cooking,meal plan,shopping list,servings"])
        ],
        reason: "人数に合わせて分量を計算できるようにしたので、日本語の説明文に一文足し、キーワードに「分量」を足す案です"
    )

    static let recipeWhatsNewJapanese = """
        ・材料の分量を、人数に合わせて自動で計算できるようになりました
        ・買い物リストを Mac と iPhone で同じものにしました
        ・写真の読み込みを速くしました
        """

    static let recipeWhatsNewEnglish = """
        - Ingredient amounts now scale automatically to the number of servings
        - Your shopping list now stays in sync between Mac and iPhone
        - Photos load faster
        """

    static let habitNotes = """
        ## 新しい機能
        - 習慣ごとに、続けた日数をカレンダーで見られるようになりました
        - ホーム画面のウィジェットから、今日の記録を付けられます

        ## 改善
        - 記録の一覧の読み込みを速くしました

        ## 不具合の修正
        - 日付が変わる直前に付けた記録が、次の日になることがあるのを直しました
        """

    static let recipeNotes = """
        ## 不具合の修正
        - 献立を複製すると、材料の分量がずれることがあるのを直しました
        """
}
