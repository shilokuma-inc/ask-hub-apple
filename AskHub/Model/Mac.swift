import Foundation

/// ワーカー（と司令塔）が動く Mac。状態リポジトリの「生きている印」から組み立てる
struct Mac: Identifiable, Hashable {
    let id: String
    /// 人が付けた名前（例: Mac mini）
    var name: String
    /// 機種（例: Mac mini（M2））。生きている印には無いので、状態リポジトリから組み立てた Mac では空
    var model: String
    var role: Role
    var residency: Residency
    var connection: Connection
    var freeBytes: Int64
    var totalBytes: Int64
    /// 負荷（0〜1）
    var load: Double
    var version: String
    var jobs: [Job]
    /// 新しいループを受けないときの理由（空き容量が少ない・版が合わない など）。受けるときは nil
    var refusalReason: String?
    var selfChecks: [SelfCheck]
    /// 期限のあるトークン（GitHub のトークンは持ち主ごと、Claude の setup-token）
    var tokens: [MacToken]
    /// 使っている Claude Code の版。分からなければ nil
    var claudeVersion: String?
    /// Claude Code の版が司令塔と違うときの、司令塔の版。そろっている・分からなければ nil
    var commanderClaudeVersion: String?
    /// ワーカーがビルドとテストに使う Xcode の版（`xcodebuild -version`）。分からなければ nil
    var xcodeVersion: String?
    /// ワーカーが作っていないもの（手で作った clone・Simulator）。人が選んで消す
    var cleanupCandidates: [CleanupCandidate]
    /// 状態リポジトリの生きている印のロードアベレージ。あれば `load` の代わりにこの値を出す
    var loadAverage: Double?
    /// この Mac が生きている印を書くときに読んだ GitHub の REST の上限の残り。読めていない（前の版の Mac）ときは nil
    var githubQuota: GitHubQuota?
    /// 互換の番号（司令塔とワーカーの間の決まりの番号）。書かない（前の版の）Mac は nil
    var compatibility: Int?
    /// 版が司令塔と違うときの、司令塔の版。互換の番号が合えば急がないので、Mac の詳細に出すだけにする。そろっている・分からなければ nil
    var commanderVersion: String?
    /// 司令塔と互換の番号が合わず、新しいジョブを引き受けていないとき。合う・照らし合わせられないときは nil
    var incompatibility: Incompatibility?

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

    /// 司令塔と互換の番号が合わない（`docs/renewal/operations.md` の「版」）
    struct Incompatibility: Hashable {
        /// 司令塔の互換の番号。司令塔の印に無い・読めないときは nil
        var commanderCompatibility: Int?
        /// ワーカーが生きている印に書いた、引き受けない理由。書いていなければ nil
        var message: String?
    }

    /// 起動したときの自己診断（Keychain・空き容量など）
    struct SelfCheck: Identifiable, Hashable {
        var id: String { name }
        var name: String
        var isOK: Bool
        var detail: String
    }
}

/// 期限のあるトークン。値そのものは持たない
struct MacToken: Identifiable, Hashable {
    enum Kind: Hashable {
        /// 持ち主（organization・個人）ごとの GitHub の fine-grained token。内訳を書かない Mac は nil
        case github(owner: String?)
        /// 持ち主ごとの管理用のトークン（常時オンの Mac の司令塔だけ。保護の設定・対象に加えるときの準備に使う）。
        /// 切れても毎日の仕事は止まらない
        case githubAdmin(owner: String)
        /// Claude の setup-token（入れた日から 1 年）
        case claude
    }

    /// 生きている印の自己診断での様子
    enum State: Hashable {
        case ok
        case missing
        case invalid
        case expired
    }

    var kind: Kind
    var state: State
    /// 期限。分からない（期限の無いトークン・前の版の Mac）ときは nil
    var expiresAt: Date?

    var id: String {
        switch kind {
        case .github(let owner): "github/\(owner ?? "")"
        case .githubAdmin(let owner): "github-admin/\(owner)"
        case .claude: "claude"
        }
    }

    /// 切れると、その Mac の仕事が止まるか。管理用のトークンは、管理の操作（保護の設定など）を断るだけで、仕事は止めない
    var stopsWork: Bool {
        if case .githubAdmin = kind {
            return false
        }
        return true
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
    /// 例: 負荷 32%・負荷 3.2（状態リポジトリの印はロードアベレージ）
    var loadText: String {
        guard let loadAverage else {
            return "負荷 \(Int(load * 100))%"
        }
        return "負荷 \(loadAverage.formatted(.number.precision(.fractionLength(1))))"
    }

    var isOnline: Bool {
        if case .online = connection {
            return true
        }
        return false
    }

    /// Mac の端末で流すコマンド（常時オンの Mac は司令塔、ほかはワーカー）
    var program: String {
        residency == .always ? "askhub-commander" : "askhub-worker"
    }

    /// トークンを入れ直すコマンド（`docs/renewal/operations.md` の「トークンの期限」）
    func renewalCommand(for token: MacToken) -> String {
        switch token.kind {
        case .github(let owner): "\(program) token \(owner ?? "<持ち主>")"
        case .githubAdmin(let owner): "askhub-commander admin-token \(owner)"
        case .claude: "\(program) claude-token"
        }
    }

    /// 司令塔とこの Mac の互換の番号を、両方読めて違うと確かめられたか。
    /// ワーカーが司令塔の印を読めずに引き受けていない（番号を比べられない）ときは false
    var comparesCompatibility: Bool {
        guard let compatibility, let commander = incompatibility?.commanderCompatibility else {
            return false
        }
        return compatibility != commander
    }

    /// 互換の番号を合わせるのに、司令塔を更新するか（この Mac のほうが新しい）。ほかはこの Mac のワーカーを更新する
    var updatesCommander: Bool {
        guard comparesCompatibility, let compatibility, let commander = incompatibility?.commanderCompatibility else {
            return false
        }
        return compatibility > commander
    }

    /// 合わない Mac で人がすること（例: ワーカーを更新する）
    var updateTitle: String {
        guard comparesCompatibility else {
            return "互換の番号を確かめる"
        }
        return updatesCommander ? "司令塔を更新する" : "ワーカーを更新する"
    }

    /// 互換の番号を合わせる手順（`docs/renewal/operations.md` の「ワーカーの更新」「司令塔の更新」）。
    /// 番号を比べられないときは、どちらを更新するか決められないので、司令塔の印と両方の版を確かめる
    var updateStep: String {
        guard comparesCompatibility else {
            return "司令塔の生きている印（commander.json）と、この Mac・司令塔の版を確かめます。古いほうを更新するか、印を直します"
        }
        if updatesCommander {
            return "手元の Mac で司令塔を更新します"
        }
        return residency == .manual
            ? "新しい askhub-worker に差し替えて、ターミナルの run を流し直します"
            : "新しい askhub-worker に差し替えて、常駐を読み込み直します"
    }

    /// 互換の番号を合わせるときに流すコマンド。番号を比べられないときは nil
    var updateCommand: String? {
        guard comparesCompatibility else {
            return nil
        }
        if updatesCommander {
            return "scripts/commander/deploy.sh"
        }
        return residency == .manual ? "askhub-worker run" : "launchctl kickstart -k gui/$(id -u)/jp.shilokuma.askhub.worker"
    }

    /// 例: この Mac は 1、司令塔は 2
    var compatibilityText: String {
        guard comparesCompatibility, let compatibility, let commander = incompatibility?.commanderCompatibility else {
            return "司令塔と互換の番号を照らし合わせられません"
        }
        return "この Mac は \(compatibility)、司令塔は \(commander)"
    }

    var usedFraction: Double {
        guard totalBytes > 0 else {
            return 0
        }
        return 1 - Double(freeBytes) / Double(totalBytes)
    }
}

extension MacToken {
    /// 期限までこれより短くなったら、入れ直しを知らせる
    static let renewalNotice: TimeInterval = 14 * 24 * 60 * 60

    enum Status: Hashable {
        /// 使える。期限が分からなければ nil
        case ok(daysLeft: Int?)
        /// 期限まで 14 日を切った
        case expiringSoon(daysLeft: Int)
        /// 期限が切れた・無い・使えない。その Mac の仕事は止まっている
        case stopped(State)
    }

    /// 期限が切れた・無い・使えない（その Mac の仕事が止まっている）。管理用のトークンは仕事を止めないので false
    func isStopped(now: Date) -> Bool {
        stopsWork && isUnusable(now: now)
    }

    /// 期限が切れた・無い・使えない
    func isUnusable(now: Date) -> Bool {
        if case .stopped = status(now: now) {
            return true
        }
        return false
    }

    func status(now: Date) -> Status {
        if state != .ok {
            return .stopped(state)
        }
        guard let expiresAt else {
            return .ok(daysLeft: nil)
        }
        let left = expiresAt.timeIntervalSince(now)
        guard left > 0 else {
            return .stopped(.expired)
        }
        // 1 日に満たない端数は 1 日に数える（残り 0 日とは出さない）
        let days = Int((left / (24 * 60 * 60)).rounded(.up))
        return left < Self.renewalNotice ? .expiringSoon(daysLeft: days) : .ok(daysLeft: days)
    }

    /// 例: GitHub のトークン（shilokuma-inc）・Claude の setup-token
    var name: String {
        switch kind {
        case .github(let owner?): "GitHub のトークン（\(owner)）"
        case .github(nil): "GitHub のトークン"
        case .githubAdmin(let owner): "管理用のトークン（\(owner)）"
        case .claude: "Claude の setup-token"
        }
    }

    /// 例: 残り 82 日・期限が切れています
    func detail(now: Date) -> String {
        switch status(now: now) {
        case .ok(let days?), .expiringSoon(let days): "残り \(days) 日"
        case .ok(nil): "期限は分かりません"
        case .stopped(.expired): "期限が切れています"
        case .stopped(.missing): "見つかりません"
        case .stopped: "使えません"
        }
    }
}
