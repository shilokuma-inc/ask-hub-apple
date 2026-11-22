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
            revision: 4,
            createdAt: ago(minutes: 60 * 3),
            updatedAt: ago(minutes: 25)
        )
        submission.screenshots = Self.recipeScreenshots
        submission.awaitsSubmission = true
        submission.canAbandon = true
        submission.canRetakeScreenshots = true
        // おこづかい帳の初めての版。App Store の準備の残り（初めての版の項目を含む）を、あなたの番に出す
        var first = Submission(
            repositoryID: Self.repositoryID("pocket-budget-ios"),
            version: "1.0.0",
            startedInAskHub: true,
            branch: "release/1.0.0",
            nextVersion: .init(version: "1.1.0", state: .merged, pullRequest: 12),
            drafts: [],
            revision: 1,
            slots: [.init(platform: "iOS")],
            createdAt: ago(minutes: 60),
            updatedAt: ago(minutes: 30)
        )
        first.canAbandon = true
        // 初めての版なので、撮った画面はすべて新しい。App Store Connect のライブラリに先に上げ、取り込みを待っている
        first.screenshots = Submission.StoreScreenshots(
            state: .capturing,
            commit: String(repeating: "d", count: 40),
            sets: [],
            skipped: [],
            progress: "App Store Connect の取り込みを待っています（2 / 5 枚）"
        )
        return [submission, first, habitSubmission()]
    }

    /// 習慣ログの 1.4.0。審査に出したら、説明文に無い機能を書いていたので断られた。人が理由を貼り、Claude の直し方の案を待っている。
    /// 振り返りの epic（実機確認が残っている）は release ブランチより前にマージしたので、「問題あり」は「このリリースで直す」が既定
    private func habitSubmission() -> Submission {
        let whatsNew = [Submission.Localized(locale: "ja", text: "・週の振り返りの画面を足しました")]
        var habit = Submission(
            repositoryID: Self.repositoryID("habit-ios"),
            version: "1.4.0",
            startedInAskHub: true,
            branch: "release/1.4.0",
            nextVersion: .init(version: "1.5.0", state: .merged, pullRequest: 48),
            builds: [.init(platform: "iOS", build: "52")],
            drafts: whatsNew,
            revision: 3,
            submitted: .init(
                builds: [.init(platform: "iOS", build: "52")], whatsNew: whatsNew, releaseType: .afterApproval, at: ago(minutes: 60 * 26)
            ),
            review: [.init(platform: "iOS", state: .rejected, since: ago(minutes: 60 * 2))],
            createdAt: ago(minutes: 60 * 30),
            updatedAt: ago(minutes: 30)
        )
        habit.branchCreatedAt = ago(minutes: 60 * 30)
        habit.canAbandon = true
        habit.rejection = Submission.Rejection(
            platforms: ["iOS"],
            text: Self.habitRejectionText,
            images: [],
            reportedAt: ago(minutes: 40),
            triage: Self.rejectionTriage
        )
        habit.canReportRejection = true
        habit.awaitsRejectionChoice = true
        return habit
    }

    /// 習慣ログ 1.4.0 の審査の文（人が App Store Connect から貼ったもの）
    static let habitRejectionText = """
        Guideline 2.3.1 - Performance - Accurate Metadata

        Your app's description mentions an Apple Watch app, but we were unable to locate it in the submission.
        """

    /// Claude の直し方の案（デモ）
    static let rejectionTriage = Submission.RejectionTriage(
        remedy: .metadata,
        summary: "説明文に、まだ出していない Apple Watch のアプリのことが書いてあり、正確でないとされた（ガイドライン 2.3.1）",
        plan: "1. 説明文から Apple Watch の文を外す（案を出し直すシートに入れた）\n2. 「審査に出し直す」で、同じビルドのまま出し直す",
        reply: "Thank you for your review. We removed the mention of the Apple Watch app from the description, "
            + "which is not included in this version.",
        metadataChanges: ["説明文（ja）"]
    )

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

    /// レシピ帳のスクショ（2 枚目のレシピの画面に、人数の欄が増えた）
    static let recipeScreenshots: Submission.StoreScreenshots = {
        let list = DemoScreen(title: "レシピ", toolbarItem: "plus", elements: [
            .search(highlighted: false),
            .row("鶏の照り焼き", detail: "20 分", highlighted: false),
            .row("具だくさん豚汁", detail: "30 分", highlighted: false)
        ])
        let before = DemoScreen(title: "鶏の照り焼き", elements: [
            .section("材料", highlighted: false),
            .row("鶏もも肉", detail: "300 g", highlighted: false),
            .row("しょうゆ", detail: "大さじ 2", highlighted: false)
        ])
        let after = DemoScreen(title: "鶏の照り焼き", elements: [
            .section("人数", highlighted: true),
            .row("4 人分", detail: nil, highlighted: true),
            .section("材料", highlighted: false),
            .row("鶏もも肉", detail: "600 g", highlighted: false),
            .row("しょうゆ", detail: "大さじ 4", highlighted: false)
        ])
        // 前回の App Store に無い位置（増えた画面）。Before が無く、「載せない」を選べる
        let added = DemoScreen(title: "買い物リスト", elements: [
            .row("鶏もも肉", detail: "600 g", highlighted: false),
            .row("しょうゆ", detail: "1 本", highlighted: false)
        ])
        // App Store Connect が受け付けなかった画面（前のままにするしかない）
        let settings = DemoScreen(title: "設定", elements: [.row("単位", detail: "g", highlighted: false)])
        let settingsAfter = DemoScreen(title: "設定", elements: [
            .row("単位", detail: "g", highlighted: false),
            .row("人数の初期値", detail: "2 人分", highlighted: true)
        ])
        let settingsArea = CGRect(x: 0, y: 0.2, width: 1, height: 0.1)
        let area = CGRect(x: 0, y: 0.12, width: 1, height: 0.22)
        func set(_ locale: String) -> Submission.ScreenshotSet {
            let shots: [Submission.Shot] = [
                .init(index: 1, name: "01-レシピ", changed: false, before: .demo(list)),
                .init(index: 2, name: "02-材料", changed: true, before: .demo(before), after: .demo(after), area: area),
                .init(index: 3, name: "03-買い物リスト", changed: true, after: .demo(added)),
                .init(
                    index: 4,
                    name: "04-設定",
                    changed: true,
                    before: .demo(settings),
                    after: .demo(settingsAfter),
                    area: settingsArea,
                    rejected: "App Store Connect が受け付けなかった（IMAGE_INCORRECT_DIMENSIONS: 画像の大きさが表示サイズに合わない）"
                )
            ]
            return Submission.ScreenshotSet(displayType: "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", locale: locale, shots: shots, removed: 0)
        }
        return Submission.StoreScreenshots(
            state: .captured,
            commit: String(repeating: "c", count: 40),
            sets: [set("ja"), set("en-US")],
            skipped: [.init(displayType: "IPAD_13_PROFILE", reason: "撮り方の設定（build.storeScreenshots.displayTypes）にこの表示サイズの機種が無い")]
        )
    }()

    /// App Store に載せる準備。家事シェアは App Store Connect にアプリがまだ無く（あなたの番に出る）、
    /// おこづかい帳はアプリを作り、初めての版（1.0.0）のリリースを始めて、初めての版に要る設定が残っている（あなたの番に出る）
    func appStoreSetups() -> [AppStoreSetup] {
        [
            AppStoreSetup(
                repositoryID: Self.repositoryID("kaji-share-ios"),
                bundleIDs: ["jp.shilokuma.KajiShare", "jp.shilokuma.KajiShareTests"],
                mainBundleID: "jp.shilokuma.KajiShare",
                items: [
                    .init(kind: .bundleId, state: .done, confirmed: false),
                    .init(
                        kind: .app,
                        state: .todo,
                        note: "App Store Connect の「アプリ」の「＋」で作る（Bundle ID と SKU は jp.shilokuma.KajiShare）",
                        confirmed: false
                    )
                ],
                isExcluded: false,
                updatedAt: ago(minutes: 40)
            ),
            AppStoreSetup(
                repositoryID: Self.repositoryID("pocket-budget-ios"),
                bundleIDs: ["jp.shilokuma.PocketBudget"],
                mainBundleID: "jp.shilokuma.PocketBudget",
                app: .init(id: "6740000123", name: "おこづかい帳", bundleID: "jp.shilokuma.PocketBudget", primaryLocale: "ja"),
                items: [
                    .init(kind: .bundleId, state: .done, confirmed: false),
                    .init(kind: .app, state: .done, confirmed: false),
                    .init(kind: .contentRights, state: .done, note: "第三者のコンテンツを使わない", confirmed: false),
                    .init(kind: .category, state: .todo, confirmed: false),
                    .init(kind: .privacyPolicy, state: .todo, note: "まだ書いていない言語: ja・en-US", confirmed: false),
                    .init(kind: .price, state: .todo, confirmed: false),
                    .init(kind: .availability, state: .todo, confirmed: false),
                    .init(kind: .ageRating, state: .todo, note: "答えていない質問が 6 個ある", confirmed: false),
                    .init(kind: .appPrivacy, state: .unknown, note: "API が無い。「App のプライバシー」で答えて公開する", confirmed: false),
                    .init(kind: .digitalServicesAct, state: .unknown, note: "API が無い。「App 情報」で DSA の申告をする", confirmed: true),
                    .init(kind: .supportUrl, state: .todo, note: "まだ書いていない言語: ja・en-US", confirmed: false),
                    .init(kind: .copyright, state: .todo, confirmed: false),
                    .init(kind: .reviewContact, state: .todo, note: "まだ入れていない欄: 電話番号", confirmed: false)
                ],
                isExcluded: false,
                updatedAt: ago(minutes: 90)
            )
        ]
    }

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
