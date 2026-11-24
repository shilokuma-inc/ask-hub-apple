import Foundation

/// 新しいアプリを App Store に載せる準備（状態リポジトリの `app-store.json`）。画面用のモデル
struct AppStoreSetup: Identifiable, Hashable {
    var id: TargetRepository.ID { repositoryID }
    var repositoryID: TargetRepository.ID
    /// リポジトリのビルドの設定にある Bundle ID（テストのターゲットのものも含む）
    var bundleIDs: [String]
    /// アプリ本体の Bundle ID（Bundle ID の登録とアプリの作成に使う）
    var mainBundleID: String?
    /// App Store Connect で見つけたアプリ。まだ無ければ nil
    var app: App?
    var items: [Item]
    /// 人が押した Bundle ID の登録（最後のもの）
    var bundleIDRequest: WriteRequest?
    /// 人が押した決まった値の書き込み（最後のもの）
    var settingsRequest: WriteRequest?
    /// App Store に出さない
    var isExcluded: Bool
    /// 初めての版を配信した時刻（準備が終わった）
    var releasedAt: Date?
    var problem: Problem?
    var updatedAt: Date

    /// Bundle ID のプラットフォーム
    enum BundlePlatform: String, CaseIterable, Hashable {
        case iOS
        case macOS
        /// iOS と macOS の両方（マルチプラットフォームのアプリ）
        case universal

        var label: String {
            switch self {
            case .iOS: "iOS"
            case .macOS: "macOS"
            case .universal: "iOS と macOS"
            }
        }
    }

    struct App: Hashable {
        /// App Store Connect のアプリの id（数字だけ）
        var id: String
        var name: String
        var bundleID: String
        var primaryLocale: String?

        /// App Store Connect のアプリの画面
        var url: URL? { URL(string: "https://appstoreconnect.apple.com/apps/\(id)/distribution") }
    }

    /// チェックリストの項目（並びは画面に出す順。`AppStoreSetupFile.ItemKind` と同じ）
    enum ItemKind: String, CaseIterable, Hashable {
        case bundleId
        case app
        case contentRights
        case category
        case privacyPolicy
        case price
        case availability
        case ageRating
        case appPrivacy
        case digitalServicesAct
        case supportUrl
        case copyright
        case reviewContact

        var title: String {
            switch self {
            case .bundleId: "Bundle ID の登録"
            case .app: "App Store Connect のアプリ"
            case .contentRights: "コンテンツの権利"
            case .category: "カテゴリ"
            case .privacyPolicy: "プライバシーポリシーの URL"
            case .price: "価格"
            case .availability: "配信の地域"
            case .ageRating: "年齢制限"
            case .appPrivacy: "App のプライバシー"
            case .digitalServicesAct: "DSA（EU のデジタルサービス法）の申告"
            case .supportUrl: "サポート URL"
            case .copyright: "著作権表示"
            case .reviewContact: "App Review の連絡先"
            }
        }

        /// App Store Connect の Web でする手順（AskHub から書けない項目）
        var guide: String? {
            switch self {
            case .app: "App Store Connect の「アプリ」の「＋」→「新規 App」で作ります。Bundle ID を選べないときは、先に Bundle ID を登録します"
            case .ageRating: "App Store Connect の「App 情報」→「年齢制限」で、質問にすべて答えます"
            case .appPrivacy: "App Store Connect の「App のプライバシー」で、集めるデータに答えて公開します。終わったら「終わった」を押します"
            case .digitalServicesAct: "App Store Connect の「App 情報」で、EU のデジタルサービス法の申告（事業者かどうか）をします。終わったら「終わった」を押します"
            case .reviewContact:
                "「値を確かめて App Store Connect に書く」で、同じ鍵のほかのアプリの連絡先を写せます。"
                    + "写せるアプリが無いときは、App Store Connect のこの版のページの「App Review に関する情報」で入れて「終わった」を押します"
            default: nil
            }
        }

        /// 決まった値を AskHub から書ける（`applyAppStoreSettings`）
        static let settingKinds: [Self] = [
            .contentRights, .category, .privacyPolicy, .price, .availability, .supportUrl, .copyright, .reviewContact
        ]

        /// アプリを作るまで（TestFlight に上げるのに要る）の項目
        var isNeededForApp: Bool { self == .bundleId || self == .app }

        /// 初めての版の項目（リリースを始めて、App Store Connect に版の枠ができてから司令塔が確かめる）
        var isVersionItem: Bool { self == .supportUrl || self == .copyright || self == .reviewContact }

        /// API で確かめられず、人が「終わった」を押す項目
        var needsConfirmation: Bool { self == .appPrivacy || self == .digitalServicesAct }
    }

    enum ItemState: Hashable {
        case todo
        case done
        /// API で読めない（人が「終わった」を押すまで終わったとみなさない）
        case unknown
    }

    struct Item: Identifiable, Hashable {
        var kind: ItemKind
        var state: ItemState
        var note: String?
        /// 人が「終わった」を押した
        var confirmed: Bool

        var id: ItemKind { kind }
        var isDone: Bool { state == .done || confirmed }
    }

    struct WriteRequest: Hashable {
        var sentAt: Date
        /// 司令塔が App Store Connect に送り終えた
        var isDone: Bool
        /// 断られた項目
        var failures: [Failure] = []
        /// App Review の連絡先を写したアプリの名前（連絡先の値は持たない）
        var reviewContactFrom: String?
    }

    struct Failure: Hashable {
        var item: ItemKind
        var message: String
    }

    struct Problem: Hashable {
        var message: String
        var needsHuman: Bool
    }

    /// 準備を見ている（出さないと決めていない・初めての版をまだ配信していない）
    var isActive: Bool { !isExcluded && releasedAt == nil }

    func item(_ kind: ItemKind) -> Item? { items.first { $0.kind == kind } }

    /// 終わっていない項目。`firstRelease` が false なら、アプリを作るまでの項目だけ
    func pendingItems(firstRelease: Bool) -> [Item] {
        guard isActive else { return [] }
        let pending = items.filter { !$0.isDone }
        return firstRelease ? pending : pending.filter { $0.kind.isNeededForApp }
    }

    /// 残りの数と、先頭の 3 つの名前（例: 残り 5 個（カテゴリ・価格・年齢制限 など））。あなたの番とリポジトリの画面のやることに出す
    static func remainingSummary(_ pending: [Item]) -> String {
        let names = pending.prefix(3).map(\.kind.title).joined(separator: "・") + (pending.count > 3 ? " など" : "")
        return "残り \(pending.count) 個（\(names)）"
    }

    /// AskHub から書ける、まだ決めていない項目
    var writableItems: [Item] {
        items.filter { ItemKind.settingKinds.contains($0.kind) && !$0.isDone }
    }

    /// 人が押した書き込みを、司令塔がまだ送り終えていない
    var isWriting: Bool {
        bundleIDRequest.map { !$0.isDone } ?? false || settingsRequest.map { !$0.isDone } ?? false
    }

    /// 最後の書き込みで断られた項目
    var failures: [Failure] {
        (bundleIDRequest?.failures ?? []) + (settingsRequest?.failures ?? [])
    }
}

/// App Store のカテゴリ（App Store Connect の `appCategories` の id と呼び名）。ゲームはサブカテゴリまで選ぶ
struct AppStoreCategoryChoice: Identifiable, Hashable {
    var primary: String
    var subcategory: String?
    var label: String

    var id: String { subcategory ?? primary }

    static let all: [Self] = [
        .init(primary: "BOOKS", label: "ブック"),
        .init(primary: "BUSINESS", label: "ビジネス"),
        .init(primary: "DEVELOPER_TOOLS", label: "デベロッパツール"),
        .init(primary: "EDUCATION", label: "教育"),
        .init(primary: "ENTERTAINMENT", label: "エンターテインメント"),
        .init(primary: "FINANCE", label: "ファイナンス"),
        .init(primary: "FOOD_AND_DRINK", label: "フード/ドリンク"),
        .init(primary: "GRAPHICS_AND_DESIGN", label: "グラフィック/デザイン"),
        .init(primary: "HEALTH_AND_FITNESS", label: "ヘルスケア/フィットネス"),
        .init(primary: "LIFESTYLE", label: "ライフスタイル"),
        .init(primary: "MEDICAL", label: "メディカル"),
        .init(primary: "MUSIC", label: "ミュージック"),
        .init(primary: "NAVIGATION", label: "ナビゲーション"),
        .init(primary: "NEWS", label: "ニュース"),
        .init(primary: "PHOTO_AND_VIDEO", label: "写真/ビデオ"),
        .init(primary: "PRODUCTIVITY", label: "仕事効率化"),
        .init(primary: "REFERENCE", label: "辞書/辞典/その他"),
        .init(primary: "SHOPPING", label: "ショッピング"),
        .init(primary: "SOCIAL_NETWORKING", label: "ソーシャルネットワーキング"),
        .init(primary: "SPORTS", label: "スポーツ"),
        .init(primary: "TRAVEL", label: "旅行"),
        .init(primary: "UTILITIES", label: "ユーティリティ"),
        .init(primary: "WEATHER", label: "天気"),
        .init(primary: "GAMES", subcategory: "GAMES_ACTION", label: "ゲーム（アクション）"),
        .init(primary: "GAMES", subcategory: "GAMES_BOARD", label: "ゲーム（ボード）"),
        .init(primary: "GAMES", subcategory: "GAMES_CARD", label: "ゲーム（カード）"),
        .init(primary: "GAMES", subcategory: "GAMES_CASUAL", label: "ゲーム（カジュアル）"),
        .init(primary: "GAMES", subcategory: "GAMES_FAMILY", label: "ゲーム（ファミリー）"),
        .init(primary: "GAMES", subcategory: "GAMES_MUSIC", label: "ゲーム（ミュージック）"),
        .init(primary: "GAMES", subcategory: "GAMES_PUZZLE", label: "ゲーム（パズル）"),
        .init(primary: "GAMES", subcategory: "GAMES_TRIVIA", label: "ゲーム（雑学）"),
        .init(primary: "GAMES", subcategory: "GAMES_WORD", label: "ゲーム（単語）")
    ]
}

/// 決まった値を書く中身（画面で選んだもの。`AppStoreSettings` の画面の形）
struct AppStoreSettingsRequest: Hashable {
    enum ContentRights: Hashable {
        case doesNotUseThirdPartyContent
        case usesThirdPartyContent
    }

    var contentRights: ContentRights?
    var category: AppStoreCategoryChoice?
    var privacyPolicyURL: String?
    /// 無料にする
    var free = false
    /// すべての地域に配信する
    var everywhere = false
    /// 初めての版のサポート URL
    var supportURL: String?
    /// 初めての版のマーケティング URL（任意。サポート URL と一緒に書く）
    var marketingURL: String?
    /// 初めての版の著作権表示
    var copyright: String?
    /// 初めての版の App Review の連絡先を、同じ鍵のほかのアプリの版から写す
    var copyReviewContact = false

    var isEmpty: Bool { items.isEmpty }

    /// 書く項目（マーケティング URL は任意なので項目を持たない）
    var items: [AppStoreSetup.ItemKind] {
        var items: [AppStoreSetup.ItemKind] = []
        if contentRights != nil { items.append(.contentRights) }
        if category != nil { items.append(.category) }
        if privacyPolicyURL != nil { items.append(.privacyPolicy) }
        if free { items.append(.price) }
        if everywhere { items.append(.availability) }
        if supportURL != nil { items.append(.supportUrl) }
        if copyright != nil { items.append(.copyright) }
        if copyReviewContact { items.append(.reviewContact) }
        return items
    }
}
