import Foundation

/// クリエイティブアセット（App Store のプロダクトページのヘッダー・検索結果の画像）の案と反映（状態リポジトリの `creative.json`。
/// `docs/renewal/creative-assets.md`）。人が案を頼むと Claude が文言・色・画面を決め、GitHub Actions で書き出す。人は画像を見て、
/// 直してほしいことを書くか承認する。承認した案は、次のリリースの「審査に出す」で載せる
struct CreativeOverview: Identifiable, Hashable {
    var id: TargetRepository.ID { repositoryID }
    var repositoryID: TargetRepository.ID
    /// 今の案。まだ頼んでいなければ nil
    var draft: Draft?
    /// 前の案（見比べるため）
    var previous: Version?
    /// 人が承認した案
    var approved: Approved?
    /// 配信中の版に置かれている画像（今の App Store）
    var live: [Image] = []
    /// 進められなかった理由（人が直す）
    var problem: String?
    var updatedAt: Date

    enum Kind: String, Hashable, CaseIterable {
        /// プロダクトページのヘッダー（21:9）
        case productPageHeader
        /// 検索結果（3:2）
        case searchResults

        var title: String {
            switch self {
            case .productPageHeader: "プロダクトページのヘッダー"
            case .searchResults: "検索結果"
            }
        }

        /// 画像の縦横の比（幅 / 高さ）
        var aspectRatio: CGFloat {
            switch self {
            case .productPageHeader: 3840.0 / 1646.0
            case .searchResults: 3840.0 / 2560.0
            }
        }

        /// 安全領域（端末によらず切れない範囲）の、画像に対する割合（Apple の Creative assets specifications）
        var safeArea: CGRect {
            switch self {
            case .productPageHeader: CGRect(x: 1097.0 / 3840, y: 493.0 / 1646, width: 1646.0 / 3840, height: 661.0 / 1646)
            case .searchResults: CGRect(x: 836.0 / 3840, y: 765.0 / 2560, width: 2168.0 / 3840, height: 1030.0 / 2560)
            }
        }
    }

    enum DraftState: Hashable {
        /// Claude が案を書いている
        case drafting
        /// GitHub Actions で書き出している
        case rendering
        /// 書き出した（人が確かめる番）
        case rendered
        /// 案か書き出しに失敗した
        case failed
    }

    /// 書き出しを止めない問題（はみ出し・安全領域の外の文字・Apple の決まりに合わない文言など）
    struct Problem: Hashable {
        var code: String
        var message: String
    }

    /// 1 枚の画像（見本は状態リポジトリのパス、今の App Store の画像は URL）
    struct Image: Hashable, Identifiable {
        var id: String { "\(locale)/\(kind.rawValue)" }
        var locale: String
        var kind: Kind
        var screenshot: Screenshot
        var problems: [Problem] = []
    }

    struct Draft: Hashable {
        var revision: Int
        var state: DraftState
        /// 人が直してほしいと書いたこと
        var comment: String?
        var requestedAt: Date
        /// Claude の案の説明
        var reason: String?
        /// 言語ごとの見出し（一覧に出す）
        var titles: [String: String] = [:]
        var images: [Image] = []
        /// 案ぜんたいの問題
        var problems: [Problem] = []
        var failure: String?
        /// 書き出しの実行の画面
        var runURL: URL?
    }

    struct Version: Hashable {
        var revision: Int
        var images: [Image]
    }

    struct Approved: Hashable {
        var revision: Int
        var images: [Image]
        var approvedAt: Date
        /// ライブラリに上げる数と、置ける状態になった数。上げる前は nil
        var libraryTotal: Int?
        var libraryReady: Int?
        /// この案を置いて審査に出した版（まだなら nil）
        var placedIn: String?

        /// 審査に出すときに置ける（ライブラリの画像がすべて置ける状態になった）
        var isPlaceable: Bool {
            guard let libraryTotal, let libraryReady else { return false }
            return libraryTotal > 0 && libraryReady == libraryTotal
        }
    }

    /// 人が確かめる番（書き出し終えた今の案を、まだ承認していない）
    var awaitsReview: Bool {
        guard let draft, draft.state == .rendered else { return false }
        return approved?.revision != draft.revision
    }

    /// 案を作っている途中（頼んだ後、書き出し終えるまで）
    var isWorking: Bool { draft.map { $0.state == .drafting || $0.state == .rendering } ?? false }

    /// 画像のある言語（今の案、無ければ承認した案。先頭が基準の言語）
    var locales: [String] {
        let images = draft?.images.isEmpty == false ? draft?.images ?? [] : approved?.images ?? []
        var locales: [String] = []
        for image in images where !locales.contains(image.locale) { locales.append(image.locale) }
        return locales
    }

    /// 様子のひとこと
    var status: String {
        if let draft {
            switch draft.state {
            case .drafting: return "案 \(draft.revision) を Claude が書いています"
            case .rendering: return "案 \(draft.revision) を書き出しています"
            case .failed: return "案 \(draft.revision) を作れませんでした"
            case .rendered where awaitsReview: return "案 \(draft.revision) を確かめる番です"
            case .rendered: break
            }
        }
        if let approved {
            if let version = approved.placedIn { return "案 \(approved.revision) を \(version) に載せました" }
            return "案 \(approved.revision) を承認済み（次のリリースで載せます）"
        }
        return "まだありません"
    }
}

extension ClientSnapshot {
    /// リポジトリのクリエイティブアセット。まだ頼んでいなければ nil
    func creative(of repositoryID: TargetRepository.ID) -> CreativeOverview? {
        creatives.first { $0.repositoryID == repositoryID }
    }
}

extension InboxBuilder {
    /// 書き出したクリエイティブアセットの案を確かめる・作れなかった（どちらも時間のあるときに）
    static func creativeItems(_ snapshot: ClientSnapshot) -> [InboxItem] {
        snapshot.creatives.compactMap { creative in
            guard let draft = creative.draft else { return nil }
            // 対象から外したリポジトリ（一覧に無い）は出さない
            guard let repository = snapshot.repositories.first(where: { $0.id == creative.repositoryID }) else { return nil }
            let title: String
            let detail: String
            if creative.awaitsReview {
                title = "ヘッダーと検索結果の案を確かめる"
                detail = draft.reason ?? "画像を見て、直してほしいことを書くか承認する"
            } else if draft.state == .failed {
                title = "ヘッダーと検索結果の案を作れませんでした"
                detail = draft.failure ?? "直してほしいことを書いて、作り直す"
            } else {
                return nil
            }
            return InboxItem(
                id: "creative/\(creative.repositoryID)/\(draft.revision)",
                urgency: .whenFree,
                kind: .creative,
                repositoryID: creative.repositoryID,
                title: title,
                context: repository.appName,
                detail: detail,
                since: creative.updatedAt,
                route: .creative(creative.repositoryID),
                targets: [.creative(creative.repositoryID)]
            )
        }
    }
}
