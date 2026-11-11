@testable import AskHub
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// Mac のトークンの期限（残り日数・入れ直しの知らせ・止まっていること）と、Claude Code の版のずれ
@MainActor
struct MacNoticeTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60
    private var snapshot: ClientSnapshot { DemoScenario.standard.snapshot(now: now) }

    private func token(_ kind: MacToken.Kind = .github(owner: "shilokuma-inc"), state: MacToken.State = .ok, days: Double?) -> MacToken {
        MacToken(kind: kind, state: state, expiresAt: days.map { now.addingTimeInterval($0 * day) })
    }

    /// 残り日数は切り上げて数え、14 日を切ったら入れ直しを知らせ、期限を過ぎたら止まっているとする
    @Test
    func tokenStatusCountsDaysLeft() {
        #expect(token(days: 82).status(now: now) == .ok(daysLeft: 82))
        #expect(token(days: 14).status(now: now) == .ok(daysLeft: 14))
        #expect(token(days: 13.9).status(now: now) == .expiringSoon(daysLeft: 14))
        #expect(token(days: 0.1).status(now: now) == .expiringSoon(daysLeft: 1))
        #expect(token(days: 0).status(now: now) == .stopped(.expired))
        #expect(token(days: nil).status(now: now) == .ok(daysLeft: nil))
        // 印を書いたときに使えなかったものは、期限が先でも止まっている
        #expect(token(state: .invalid, days: 30).status(now: now) == .stopped(.invalid))
        #expect(token(.claude, days: 3).detail(now: now) == "残り 3 日")
        #expect(token(.claude, days: nil).detail(now: now) == "期限は分かりません")
        #expect(token(days: -1).detail(now: now) == "期限が切れています")
    }

    /// 期限まで 14 日を切ったトークンは、入れ直すコマンドとともに「時間のあるときに」へ出す
    @Test
    func expiringTokenAsksForRenewalWithCommand() throws {
        let items = InboxBuilder.items(from: snapshot, now: now)
        let item = try #require(items.first { $0.id == "mac/\(DemoData.macBookProID)/token/github/\(DemoData.owner)" })
        #expect(item.urgency == .whenFree)
        #expect(item.kind == .token)
        #expect(item.title == "トークンを入れ直す")
        #expect(item.detail == "GitHub のトークン（\(DemoData.owner)）があと 10 日で切れます · askhub-worker token \(DemoData.owner)")
        #expect(item.route == .mac(DemoData.macBookProID))
        // 期限の遠いトークンは知らせない
        #expect(items.filter { $0.kind == .token }.count == 1)
    }

    /// 期限が切れたら、止まっていることを進行を止めるものとして出す（常時オンの Mac は司令塔のコマンド）
    @Test
    func expiredTokenIsShownAsStopped() throws {
        var snapshot = snapshot
        snapshot.updateMac(DemoData.macMiniID) { mac in
            mac.tokens = [token(days: 60), token(.claude, days: -2)]
        }
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.id == "mac/\(DemoData.macMiniID)/token/claude" })
        #expect(item.urgency == .blocking)
        #expect(item.title == "トークンの期限が切れて止まっています")
        #expect(item.detail == "Claude の setup-token · askhub-commander claude-token")
        #expect(item.since == now.addingTimeInterval(-2 * day))
    }

    /// 状態リポジトリのトークンが切れて印を書けない Mac も、しばらくは知らせる。長くオフラインの Mac では知らせない
    @Test
    func tokenNoticeStopsForLongOfflineMac() {
        var snapshot = snapshot
        snapshot.updateMac(DemoData.macBookAirID) { mac in
            mac.tokens = [token(days: -1)]
            mac.connection = .offline(since: now.addingTimeInterval(-2 * day))
        }
        let id = "mac/\(DemoData.macBookAirID)/token/github/shilokuma-inc"
        #expect(InboxBuilder.items(from: snapshot, now: now).contains { $0.id == id })
        snapshot.updateMac(DemoData.macBookAirID) { $0.connection = .offline(since: now.addingTimeInterval(-8 * day)) }
        #expect(!InboxBuilder.items(from: snapshot, now: now).contains { $0.id == id })
    }

    /// Claude Code の版が司令塔と違うオンラインの Mac を知らせる
    @Test
    func claudeVersionMismatchIsShownForOnlineMac() throws {
        let item = try #require(InboxBuilder.items(from: snapshot, now: now).first { $0.kind == .claudeVersion })
        #expect(item.id == "mac/\(DemoData.macBookProID)/claude-version")
        #expect(item.urgency == .whenFree)
        #expect(item.detail == "この Mac は 2.1.316、司令塔は 2.1.320")
        var offline = snapshot
        offline.updateMac(DemoData.macBookProID) { $0.connection = .offline(since: now.addingTimeInterval(-60 * 60)) }
        #expect(!InboxBuilder.items(from: offline, now: now).contains { $0.kind == .claudeVersion })
    }

    // MARK: 状態リポジトリから

    /// 生きている印の自己診断から、持ち主ごとのトークンの期限と Claude Code の版のずれを組み立てる
    @Test
    func buildsTokensAndClaudeVersionFromHeartbeats() async throws {
        let files = [
            "commander.json": """
            {"v":1,"mac":"mac-mini","seenAt":"2027-01-15T07:50:00Z","versions":{"commander":"1.0.0","claude":"2.1.320"},
             "selfCheck":{"checkedAt":"2027-01-15T07:50:00Z","keychain":"ok","githubToken":"ok","claudeToken":"ok"}}
            """,
            "macs/mac-mini.json": heartbeat(mac: "mac-mini", kind: "alwaysOn", claude: "2.1.320", selfCheck: """
                {"checkedAt":"2027-01-15T07:50:00Z","keychain":"ok","githubToken":"ok","claudeToken":"ok",
                 "githubTokenExpiresAt":"2027-01-20T00:00:00Z","claudeTokenExpiresAt":"2027-11-01T00:00:00Z",
                 "githubTokens":[{"owner":"shilokuma-inc","state":"ok","expiresAt":"2027-01-20T00:00:00Z"},
                                 {"owner":"mrs1669","state":"ok"}]}
                """),
            "macs/macbook-a.json": heartbeat(mac: "macbook-a", kind: "resident", claude: "2.1.316", selfCheck: """
                {"checkedAt":"2027-01-15T07:50:00Z","keychain":"ok","githubToken":"expired","claudeToken":"ok",
                 "githubTokenExpiresAt":"2027-01-10T00:00:00Z"}
                """)
        ]
        let store = InMemoryStateStore(files: files.mapValues { Data($0.utf8) })
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let now = now
        let snapshot = try await StateClientService(store: store, key: key) { now }.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)

        let mini = try #require(snapshot.macs.first { $0.id == "mac-mini" })
        #expect(mini.tokens.map(\.kind) == [.github(owner: "shilokuma-inc"), .github(owner: "mrs1669"), .claude])
        #expect(mini.tokens.first?.status(now: now) == .expiringSoon(daysLeft: 5))
        #expect(mini.tokens[1].status(now: now) == .ok(daysLeft: nil))
        #expect(mini.claudeVersion == "2.1.320")
        #expect(mini.commanderClaudeVersion == nil)
        #expect(mini.refusalReason == nil)

        // 持ち主の内訳の無い（前の版の）Mac は、まとめた様子を 1 つにして出す
        let laptop = try #require(snapshot.macs.first { $0.id == "macbook-a" })
        #expect(laptop.tokens.map(\.kind) == [.github(owner: nil), .claude])
        #expect(laptop.tokens.first?.status(now: now) == .stopped(.expired))
        #expect(laptop.refusalReason == "GitHub のトークンの期限が切れて止まっています")
        #expect(laptop.commanderClaudeVersion == "2.1.320")
        #expect(laptop.renewalCommand(for: try #require(laptop.tokens.first)) == "askhub-worker token <持ち主>")
    }

    /// 生きている印の自己診断の残り（持ち主ごとのうち一番少ないもの）を Mac に付け、全体では一番新しく読んだ今の窓のものを使う
    @Test
    func buildsGitHubQuotaFromHeartbeats() async throws {
        let files = [
            "macs/mac-mini.json": heartbeat(mac: "mac-mini", kind: "alwaysOn", claude: "2.1.320", selfCheck: """
                {"checkedAt":"2027-01-15T07:58:00Z","keychain":"ok","githubToken":"ok","claudeToken":"ok",
                 "githubTokens":[
                   {"owner":"shilokuma-inc","state":"ok","rateLimit":{"limit":5000,"remaining":4210,"resetAt":"2027-01-15T08:41:00Z"}},
                   {"owner":"mrs1669","state":"ok","rateLimit":{"limit":5000,"remaining":4190,"resetAt":"2027-01-15T08:41:00Z"}}]}
                """),
            "macs/macbook-a.json": heartbeat(mac: "macbook-a", kind: "resident", claude: "2.1.320", selfCheck: """
                {"checkedAt":"2027-01-15T07:50:00Z","keychain":"ok","githubToken":"ok","claudeToken":"ok",
                 "githubTokens":[
                   {"owner":"mrs1669","state":"ok","rateLimit":{"limit":5000,"remaining":4400,"resetAt":"2027-01-15T08:41:00Z"}}]}
                """),
            "macs/macbook-b.json": heartbeat(mac: "macbook-b", kind: "resident", claude: "2.1.320", selfCheck: """
                {"checkedAt":"2027-01-15T07:50:00Z","keychain":"ok","githubToken":"ok","claudeToken":"ok"}
                """)
        ]
        let store = InMemoryStateStore(files: files.mapValues { Data($0.utf8) })
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let now = now
        let snapshot = try await StateClientService(store: store, key: key) { now }.fetchSnapshot()

        let resetAt = try #require(Timestamp(rawValue: "2027-01-15T08:41:00Z")).date
        let checkedAt = try #require(Timestamp(rawValue: "2027-01-15T07:58:00Z")).date
        let quota = GitHubQuota(limit: 5_000, remaining: 4_190, resetAt: resetAt, checkedAt: checkedAt)
        #expect(snapshot.mac("mac-mini")?.githubQuota == quota)
        // 残りを書かない（前の版の）Mac は持たない
        #expect(snapshot.mac("macbook-b")?.githubQuota == nil)
        // 上限はアカウントごとなので、一番新しく読んだものを使う。戻る時刻を過ぎたら使わない
        #expect(snapshot.githubQuota(now: now) == quota)
        #expect(snapshot.githubQuota(now: resetAt) == nil)
        #expect(!quota.isLow(now: now))
        var low = quota
        low.remaining = 999
        #expect(low.isLow(now: now))
        #expect(!low.isLow(now: resetAt))
    }

    private func heartbeat(mac: String, kind: String, claude: String, selfCheck: String) -> String {
        """
        {"v":1,"mac":"\(mac)","kind":"\(kind)","seenAt":"2027-01-15T07:50:00Z","versions":{"worker":"1.0.0","claude":"\(claude)"},
         "diskFreeGB":120,"load":0.5,"capacity":{"claude":2,"build":1},"selfCheck":\(selfCheck)}
        """
    }
}
