import Foundation

/// リポジトリの画面の一番上の「やること」の 1 行。あなたの番のうちこのリポジトリのものと、リポジトリの設定の残り
/// （App Store の準備・加えるときの準備・ビルドの設定・保護・app-kit）を並べる（ユーザーの決定。2026-11-24）
struct RepositoryTodo: Identifiable, Hashable {
    /// 押したときの行き先
    enum Action: Hashable {
        /// 画面を開く
        case route(AppRoute)
        /// ビルドの設定のシートを開く
        case buildSettings
        /// 保護の設定のシートを開く
        case protection
        /// 同じ画面の下の「加えるときの準備」まで送る（承認・やり直しはその節で確かめてから押す）
        case setup
    }

    var id: String
    /// 行の印（あなたの番と同じ印と色）
    var kind: InboxItem.Kind
    var title: String
    var detail: String
    var action: Action
    /// 送った操作が反映を待っていれば、行に印を出す
    var targets: [IntentTarget] = []
}

extension RepositoryTodo {
    /// あなたの番の行から作る
    init(_ item: InboxItem, action: Action) {
        self.init(id: item.id, kind: item.kind, title: item.title, detail: item.detail, action: action, targets: item.targets)
    }

    /// リポジトリのやること。あなたの番の行（急ぎを先に）、App Store の準備の残り、加えるときの準備、ビルドの設定・保護・app-kit の順。
    /// あなたの番でこのリポジトリの画面を開く行（保護のずれ・加えるときの準備・app-kit のずれ）は、この画面の中の行き先に置き換える。
    /// 外したリポジトリは、あなたの番の行だけを出す
    static func items(for repository: TargetRepository, inbox: [InboxItem], snapshot: ClientSnapshot) -> [RepositoryTodo] {
        var items = inbox
            .filter { $0.repositoryID == repository.id && $0.route != .repository(repository.id) }
            .map { RepositoryTodo($0, action: .route($0.route)) }
        guard !snapshot.isRemoved(repository.id) else {
            return items
        }
        // App Store の準備は、あなたの番に出ていればその行で足りる（リリースを始めるまでは、あなたの番に出さない残りもここに出す）
        if let setup = appStoreSetupTodo(repository, snapshot: snapshot), !items.contains(where: { $0.action == setup.action }) {
            items.append(setup)
        }
        items += InboxBuilder.setupItems(repository).map { RepositoryTodo($0, action: .setup) }
        if repository.build == nil {
            items.append(RepositoryTodo(
                id: "repository/\(repository.id)/build",
                kind: .repositorySetup,
                title: "ビルドの設定を入れる",
                detail: "まだありません。開始する前に入れてください",
                action: .buildSettings,
                targets: [.repository(repository.id)]
            ))
        }
        if let protection = protectionTodo(repository) {
            items.append(protection)
        }
        return items + appKitTodos(repository, overview: snapshot.appKit)
    }

    /// App Store の準備の残り（アプリを作るまでと、初めての版の項目）
    private static func appStoreSetupTodo(_ repository: TargetRepository, snapshot: ClientSnapshot) -> RepositoryTodo? {
        guard let setup = snapshot.appStoreSetup(of: repository.id) else {
            return nil
        }
        let pending = setup.pendingItems(firstRelease: true)
        guard !pending.isEmpty else {
            return nil
        }
        return RepositoryTodo(
            id: "appStore/\(repository.id)/remaining",
            kind: .appStoreSetup,
            title: "App Store の準備を終える",
            detail: AppStoreSetup.remainingSummary(pending),
            action: .route(.appStoreSetup(repository.id)),
            targets: [.appStore(repository.id)]
        )
    }

    /// 保護をまだ掛けていない・ずれている
    private static func protectionTodo(_ repository: TargetRepository) -> RepositoryTodo? {
        let title: String
        let detail: String
        switch repository.protection?.state {
        case .notApplied:
            title = "保護を掛ける"
            detail = repository.protection?.rejection ?? "develop・main・release/ の下に、まだ掛けていません"
        case let .drifted(_, problems, _):
            title = "保護のずれを直す"
            detail = problems.joined(separator: "・")
        case .applied, nil:
            return nil
        }
        return RepositoryTodo(
            id: "repository/\(repository.id)/protection",
            kind: .repositorySetup,
            title: title,
            detail: detail,
            action: .protection,
            targets: [.repository(repository.id)]
        )
    }

    /// app-kit の残り（まだ入れ替えていない・ずれ・このリポジトリで広げる途中で止まった・新しい版をまだ広げていない）
    private static func appKitTodos(_ repository: TargetRepository, overview: AppKitOverview?) -> [RepositoryTodo] {
        guard let appKit = repository.appKit else {
            return []
        }
        func todo(_ suffix: String, title: String, detail: String, action: Action = .route(.appKit)) -> RepositoryTodo {
            let id = "repository/\(repository.id)/app-kit/\(suffix)"
            return RepositoryTodo(id: id, kind: .appKit, title: title, detail: detail, action: action, targets: [.appKit])
        }
        guard let installed = appKit.installed else {
            // 入れ替えは「加えるときの準備」の PR で行う。PR の承認を待っていればその行で足り、準備を流していなければ押す所が無い
            guard repository.setup != nil, repository.setup?.workflowPullRequest?.state != .open else {
                return []
            }
            let detail = "「加えるときの準備」の「準備をやり直す」で、入れ替える PR を出します"
            return [todo("install", title: "app-kit に入れ替える", detail: detail, action: .setup)]
        }
        var items: [RepositoryTodo] = []
        if !installed.drift.isEmpty {
            items.append(todo("drift", title: "app-kit のずれを直す", detail: installed.drift.joined(separator: "・")))
        }
        if let version = appKit.rolloutVersion, let target = appKit.rolloutTarget, target.state == .failed {
            let detail = target.problem ?? "app-kit の画面で、もう一度試すか、やめる"
            items.append(todo("failed", title: "app-kit \(version) を広げる途中で止まりました", detail: detail))
        } else if let overview, let release = overview.newRelease, overview.canRollOut(release), installed.isOlder(than: release.version) {
            let detail = "このリポジトリは \(installed.versionLabel)。app-kit の画面で変更点を見て広げます"
            items.append(todo("release", title: "app-kit \(release.version) を広げる", detail: detail))
        }
        return items
    }
}
