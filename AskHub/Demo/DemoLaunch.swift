import Foundation

#if DEBUG
/// UI テストと撮影のために、起動引数で開く画面を決める（DEBUG だけ）。
///
/// 例: `-demoOpen deck:all`・`-demoOpen deck:verifications`（アプリをまたいだ実機確認）・`-demoOpen epic:rain-draft`・`-demoOpen section:macs`・`-demoOpen finished`（終わったものをすべて）、
/// `-demoOpen verifications`（実機確認の一覧。`verifications:folded` なら配信した版の確認を開いておく）、
/// `-demoOpen release:demo-studio/habit-ios:1.2.0`（配信した版）・`-demoOpen appStore:demo-studio/pocket-budget-ios`（App Store の準備）、
/// スワイプの途中の色を撮るときは `-demoDrag 0:0.8`（選択肢の添字:進み具合）、
/// 開いた画面のシートを撮るときは `-demoSheet start`（ゴールの画面の、Mac を選ぶシート）・`-demoSheet submitReview`（審査に出す）・
/// `-demoSheet startRelease`（リリースを始める）・`-demoSheet fixRelease`（このリリースを直す依頼）・`-demoSheet rejectionReport`（リジェクトの理由を貼る）・`-demoSheet appStoreSettings`（App Store Connect に決まった値を書く）・
/// `-demoSheet settings`（iOS の設定のシート）・`-demoSheet closeVerifications`（実機確認の一覧の、確かめずに閉じる理由のシート）。
/// テーマは `-appTheme dark` のように保存のキーを起動引数で渡すと、保存された値によらずその見た目で撮れる
enum DemoLaunch {
    static let openKey = "demoOpen"
    static let dragKey = "demoDrag"
    static let sheetKey = "demoSheet"

    /// 開いた画面で、最初から開いておくシート（撮影用）
    enum Sheet: String {
        /// ゴールの画面の、開始のときに回す Mac を選ぶシート
        case start
        /// リリースを始めた版の画面の、審査に出すシート
        case submitReview
        /// リポジトリの画面の、リリースを始めるシート
        case startRelease
        /// リリースを始めた版の画面の、このリリースを直す依頼のシート
        case fixRelease
        /// リリースを始めた版の画面の、リジェクトの理由を貼るシート
        case rejectionReport
        /// App Store の準備の画面の、決まった値を書くシート
        case appStoreSettings
        /// 設定のシート（iOS。macOS は設定のウィンドウなので開かない）
        case settings
        /// 実機確認の一覧の、先頭の epic を確かめずに閉じる理由のシート
        case closeVerifications
    }

    static func initialSheet(defaults: UserDefaults = .standard) -> Sheet? {
        defaults.string(forKey: sheetKey).flatMap(Sheet.init(rawValue:))
    }

    /// 実機確認の一覧で、配信した版の確認（畳んだもの）を開いておくか（`-demoOpen verifications:folded`）
    static func expandsFoldedVerifications(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: openKey) == "verifications:folded"
    }

    static func initialDestination(defaults: UserDefaults = .standard) -> (section: AppSection, route: AppRoute?)? {
        guard let value = defaults.string(forKey: openKey) else {
            return nil
        }
        return destination(from: value)
    }

    static func destination(from value: String) -> (section: AppSection, route: AppRoute?)? {
        let parts = value.split(separator: ":").map(String.init)
        guard let kind = parts.first else {
            return nil
        }
        let argument = parts.dropFirst().first ?? ""
        if let (section, makeRoute) = singleArgumentRoutes[kind] {
            return (section, makeRoute(argument))
        }
        if let (section, route) = noArgumentRoutes[kind] {
            return (section, route)
        }
        switch kind {
        case "section":
            return AppSection(rawValue: argument).map { ($0, nil) }

        case "deck":
            return deck(parts).map { (.inbox, .deck($0)) }

        case "human":
            return parts.count == 3 ? (.inbox, .humanTask(epicID: parts[1], taskID: parts[2])) : nil

        case "release":
            // `release:<リポジトリの id>:<版>`（例: `release:demo-studio/habit-ios:1.2.0`）
            return parts.count == 3 ? (.repositories, .release(repositoryID: parts[1], version: parts[2])) : nil

        case "submission":
            // `submission:<リポジトリの id>:<版>`（例: `submission:demo-studio/recipe-apple:2.1.0`）
            return parts.count == 3 ? (.repositories, .submission(repositoryID: parts[1], version: parts[2])) : nil

        default:
            return nil
        }
    }

    /// 引数の要らない行き先（例: `finished`。`verifications:folded` は一覧を開き、畳んだ確認を開いておく）
    private static let noArgumentRoutes: [String: (AppSection, AppRoute)] = [
        "finished": (.progress, .finishedEpics),
        "appKit": (.repositories, .appKit),
        "verifications": (.inbox, .verifications)
    ]

    /// 引数が 1 つの行き先（例: `epic:rain-draft`）
    private static let singleArgumentRoutes: [String: (AppSection, (String) -> AppRoute)] = [
        "epic": (.progress, AppRoute.epic),
        "goal": (.inbox, AppRoute.goal),
        "final": (.inbox, AppRoute.finalReview),
        "mac": (.macs, AppRoute.mac),
        "cleanup": (.macs, AppRoute.cleanup),
        "repository": (.repositories, AppRoute.repository),
        "appStore": (.repositories, AppRoute.appStoreSetup),
        "creative": (.repositories, AppRoute.creative)
    ]

    private static func deck(_ parts: [String]) -> DeckScope? {
        guard parts.count >= 2 else {
            return nil
        }
        if parts[1] == "all" {
            return .all
        }
        // epic を付けない `deck:verifications` は、アプリをまたいで実機確認をすべて
        if parts == ["deck", "verifications"] {
            return .allVerifications
        }
        guard parts.count == 3 else {
            return nil
        }
        switch parts[1] {
        case "questions": return .questions(parts[2])
        case "decisions": return .decisions(parts[2])
        case "verifications": return .verifications(parts[2])
        default: return nil
        }
    }

    /// スワイプの途中の状態（撮影用）
    static func dragPreview(defaults: UserDefaults = .standard) -> SwipeDragState? {
        guard let value = defaults.string(forKey: dragKey) else {
            return nil
        }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let index = Int(parts[0]), let progress = Double(parts[1]) else {
            return nil
        }
        return SwipeDragState(candidate: index, progress: min(1, max(0, progress)))
    }
}
#endif
