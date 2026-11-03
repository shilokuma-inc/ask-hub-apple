import Foundation

/// ワーカー（と司令塔）が動く Mac。状態リポジトリの「生きている印」から組み立てる
struct Mac: Identifiable, Hashable {
    let id: String
    /// 人が付けた名前（例: Mac mini）
    var name: String
    /// 機種（例: Mac mini（M2））
    var model: String
    var role: Role
    var residency: Residency
    var connection: Connection
    var freeBytes: Int64
    var totalBytes: Int64
    /// 負荷（0〜1）
    var load: Double
    var version: String
    /// 司令塔と版が合っているか。合わないときはジョブを受けない
    var versionMatches: Bool
    var jobs: [Job]
    /// 新しいループを受けないときの理由（空き容量が少ない・版が合わない など）。受けるときは nil
    var refusalReason: String?
    var selfChecks: [SelfCheck]
    /// ワーカーが作っていないもの（手で作った clone・Simulator）。人が選んで消す
    var cleanupCandidates: [CleanupCandidate]

    enum Role: Hashable {
        /// 常時オンで、司令塔とワーカーが動く
        case commandCenter
        case worker
    }

    enum Residency: Hashable {
        /// launchd で常駐（常時オン）
        case always
        /// launchd で常駐。開いている間だけ動く
        case whileOpen
        /// 常駐できない。ターミナルのコマンドで起動する
        case manual
    }

    enum Connection: Hashable {
        case online(lastSeen: Date)
        /// 閉じた・ネットワークから外れた。ジョブは一時停止している
        case offline(since: Date)
    }

    /// その Mac が持っているジョブ
    struct Job: Identifiable, Hashable {
        let id: String
        var title: String
        var epicID: Epic.ID?
        var startedAt: Date
    }

    /// 起動したときの自己診断（トークン・Keychain・空き容量など）
    struct SelfCheck: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var isOK: Bool
        var detail: String
    }
}

/// 片付けの候補（ワーカーが作っていないもの）
struct CleanupCandidate: Identifiable, Hashable {
    let id: String
    var kind: Kind
    var name: String
    var bytes: Int64
    /// 消す前に確かめたこと（未 push のコミット・stash など）。問題が無ければ nil
    var caution: String?

    enum Kind: Hashable {
        case clone
        case simulator
        case derivedData
    }
}

extension Mac {
    var isOnline: Bool {
        if case .online = connection {
            return true
        }
        return false
    }

    var usedFraction: Double {
        guard totalBytes > 0 else {
            return 0
        }
        return 1 - Double(freeBytes) / Double(totalBytes)
    }
}
