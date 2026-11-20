import AskHubProtocol
import Foundation

/// 通知から開く先。司令塔が通知の中身の `askhub` に入れる（epic の出来事は `repo`・`epic`、Mac は `mac`、
/// App Store で配信した版は `repo`・`release`、リリースを始めた版は `repo`・`submission`、App Store に載せる準備は `repo`・`appStore`、
/// いくつもの epic の実機確認のまとめは `verification`。`docs/renewal/protocol.md`）
nonisolated enum PushTarget: Equatable, Sendable {
    case epic(repo: RepositoryFullName, epic: ULID)
    case mac(MacName)
    case release(repo: RepositoryFullName, version: MarketingVersion)
    case submission(repo: RepositoryFullName, version: MarketingVersion)
    /// 新しいアプリを App Store に載せる準備（`{"repo", "appStore": "setup"}`）
    case appStore(repo: RepositoryFullName)
    /// アプリをまたいだ実機確認（`{"verification": "all"}`）
    case verifications

    /// 通知の中身から読む。形の違う値（パスの文字を含むなど）は開かない
    init?(userInfo: [AnyHashable: Any]) {
        guard let target = userInfo["askhub"] as? [String: Any] else {
            return nil
        }
        if let repo = (target["repo"] as? String).flatMap(RepositoryFullName.init(rawValue:)),
           let epic = (target["epic"] as? String).flatMap(ULID.init(rawValue:)) {
            self = .epic(repo: repo, epic: epic)
        } else if let repo = (target["repo"] as? String).flatMap(RepositoryFullName.init(rawValue:)),
                  let version = (target["release"] as? String).flatMap(MarketingVersion.init(rawValue:)) {
            self = .release(repo: repo, version: version)
        } else if let repo = (target["repo"] as? String).flatMap(RepositoryFullName.init(rawValue:)),
                  let version = (target["submission"] as? String).flatMap(MarketingVersion.init(rawValue:)) {
            self = .submission(repo: repo, version: version)
        } else if let repo = (target["repo"] as? String).flatMap(RepositoryFullName.init(rawValue:)),
                  target["appStore"] as? String == "setup" {
            self = .appStore(repo: repo)
        } else if let mac = (target["mac"] as? String).flatMap(MacName.init(rawValue:)) {
            self = .mac(mac)
        } else if target["verification"] as? String == "all" {
            self = .verifications
        } else {
            return nil
        }
    }

    var section: AppSection {
        switch self {
        case .epic: .progress
        case .mac: .macs
        case .release, .submission, .appStore: .repositories
        case .verifications: .inbox
        }
    }

    var route: AppRoute {
        switch self {
        case let .epic(_, epic): .epic(epic.rawValue)
        case .mac(let mac): .mac(mac.rawValue)
        // 画面のリポジトリの id は owner/name を小文字にしたもの（`TargetRepository.id`）
        case let .release(repo, version): .release(repositoryID: repo.rawValue.lowercased(), version: version.rawValue)
        case let .submission(repo, version): .submission(repositoryID: repo.rawValue.lowercased(), version: version.rawValue)
        case .appStore(let repo): .appStoreSetup(repo.rawValue.lowercased())
        case .verifications: .deck(.allVerifications)
        }
    }
}

extension AppNavigator {
    /// 通知から、該当の epic・Mac・版の画面や、実機確認のカードを開く
    func open(_ target: PushTarget) {
        open(target.route, in: target.section)
    }
}
