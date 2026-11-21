import Foundation

/// 1 回の取得で読んだ状態の全体。画面はすべてここから組み立てる
struct ClientSnapshot: Hashable {
    var repositories: [TargetRepository]
    /// まだ対象になっていないリポジトリ（「対象に加える」で選ぶ候補）
    var candidateRepositories: [TargetRepository]
    /// 対象から外したリポジトリ（`repo.json` は残っている）。「対象に加える」で戻せる。終わった epic の名前とアイコンにも使う
    var removedRepositories: [TargetRepository] = []
    var epics: [Epic]
    var macs: [Mac]
    var fetchedAt: Date
    /// 一部の取得元だけ読めなかったとき。空なら全部読めた
    var sourceFailures: [SourceFailure]
    /// この端末が送った人の意図と、その処理の結果（新しい順）。状態リポジトリにつないだときだけ持つ
    var sentIntents: [SentIntentStatus] = []
    /// 司令塔の生きている印の時刻（`commander.json` の `seenAt`）。読めていなければ nil
    var commanderSeenAt: Date?
    /// App Store で配信した版と、その後作業（リポジトリの順、その中は新しい版から）
    var releases: [Release] = []
    /// リリースを始めた版（準備から配信まで）。リポジトリの順、その中は新しい版から
    var submissions: [Submission] = []
    /// 新しいアプリを App Store に載せる準備（リポジトリの順）
    var appStoreSetups: [AppStoreSetup] = []
}

/// 送った人の意図の処理の結果
struct SentIntentStatus: Identifiable, Hashable {
    let id: String
    /// 例: 回答（献立メモ · Q3）
    var title: String
    var sentAt: Date
    var state: State
    /// 意図が働きかける画面の要素。画面の要素に結びつかない意図（鍵の登録など）は nil
    var target: IntentTarget?

    enum State: Hashable {
        /// 司令塔がまだ処理していない
        case waiting
        case accepted(at: Date)
        case rejected(at: Date, reason: String)
    }
}

/// 読めなかった取得元。「取得に失敗した」と「0 件」を分けて出すために持つ
struct SourceFailure: Hashable {
    /// 例: 状態リポジトリ
    var source: String
    var message: String
}

extension ClientSnapshot {
    /// 対象のリポジトリ。外したリポジトリも返す（外す前の epic の名前とアイコンを出すため）
    func repository(_ id: TargetRepository.ID) -> TargetRepository? {
        repositories.first { $0.id == id } ?? removedRepositories.first { $0.id == id }
    }

    /// 対象から外したリポジトリか
    func isRemoved(_ id: TargetRepository.ID) -> Bool {
        !repositories.contains { $0.id == id } && removedRepositories.contains { $0.id == id }
    }

    /// 対象のリポジトリを持ち主（organization）ごとにまとめたもの。依頼のシートとリポジトリのタブで見出しを付けて並べる
    var repositoryGroups: [RepositoryOwnerGroup] {
        RepositoryOwnerGroup.grouping(repositories)
    }

    /// リポジトリの配信した版（新しい版から）
    func releases(of repositoryID: TargetRepository.ID) -> [Release] {
        releases.filter { $0.repositoryID == repositoryID }
    }

    func release(_ id: Release.ID) -> Release? {
        releases.first { $0.id == id }
    }

    /// リポジトリの App Store の準備。記録が無ければ nil
    func appStoreSetup(of repositoryID: TargetRepository.ID) -> AppStoreSetup? {
        appStoreSetups.first { $0.repositoryID == repositoryID }
    }

    /// 配信中の版が無いアプリで、リリースを始めている（初めての版の準備の残りも出す）
    func isFirstRelease(of repositoryID: TargetRepository.ID) -> Bool {
        guard let setup = appStoreSetup(of: repositoryID), setup.isActive, setup.app != nil else { return false }
        return submissions(of: repositoryID).contains { !$0.isEnded }
    }

    /// リポジトリのリリースを始めた版（新しい版から）
    func submissions(of repositoryID: TargetRepository.ID) -> [Submission] {
        submissions.filter { $0.repositoryID == repositoryID }
    }

    func submission(_ id: Submission.ID) -> Submission? {
        submissions.first { $0.id == id }
    }

    /// リリースを始めるときの版の既定（前に配信した版の次のマイナー。develop の版を上げた PR があれば、その版）
    func suggestedReleaseVersion(of repositoryID: TargetRepository.ID) -> String {
        guard let latest = releases(of: repositoryID).max(by: { Self.isOlder($0.version, $1.version) }) else { return "1.0.0" }
        if let next = latest.nextVersion?.version, Self.isOlder(latest.version, next) { return next }
        var parts = latest.version.split(separator: ".").compactMap { Int($0) }
        while parts.count < 3 { parts.append(0) }
        return "\(parts[0]).\(parts[1] + 1).0"
    }

    /// 版の番号を数の並びとして比べる（`1.10.0` は `1.9.0` より大きい）
    static func isOlder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        return (left + Array(repeating: 0, count: count - left.count))
            .lexicographicallyPrecedes(right + Array(repeating: 0, count: count - right.count))
    }

    func epic(_ id: Epic.ID) -> Epic? {
        epics.first { $0.id == id }
    }

    func mac(_ id: Mac.ID?) -> Mac? {
        guard let id else {
            return nil
        }
        return macs.first { $0.id == id }
    }

    var activeEpics: [Epic] {
        epics.filter(\.isActive)
    }

    /// 今の窓の GitHub の REST の上限の残り。Mac ごとの印のうち一番新しく読んだもの（上限はアカウントごとなので、どの Mac も同じ回数を数える）。
    /// どの Mac も書いていない・戻る時刻を過ぎていれば nil
    func githubQuota(now: Date) -> GitHubQuota? {
        macs.compactMap(\.githubQuota)
            .filter { $0.isCurrent(now: now) }
            .max { ($0.checkedAt, -$0.remaining) < ($1.checkedAt, -$1.remaining) }
    }

    /// 開始のときに選べる Mac（オンラインの Mac すべて）
    var startableMacs: [Mac] {
        macs.filter(\.isOnline)
    }

    /// 開始のときに既定で選ぶ Mac。前回そのリポジトリを回した Mac が、オンラインで新しいループを受けるときだけ選ぶ
    func defaultStartMacID(for repositoryID: TargetRepository.ID) -> Mac.ID? {
        guard let mac = mac(repository(repositoryID)?.lastMacID), mac.isOnline, mac.refusalReason == nil else {
            return nil
        }
        return mac.id
    }
}
