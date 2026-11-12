import AskHubKeychain
import AskHubProtocol
import Foundation

/// 生きている印に書く、この Mac の様子（空き容量・負荷・自己診断・Claude と Xcode の版）
public struct MachineProbe: Sendable {
    public var secrets: any SecretStore
    /// 空き容量を測るフォルダ（作業ファイルを置くボリューム）
    public var volume: URL
    /// GitHub のトークンを置く持ち主（`MachineConfiguration.tokenOwners`）。どれか 1 つでも無ければ `missing`。
    /// 自己診断のたびに呼ぶ（常駐は設定ファイルから読み直し、`token` で足した持ち主を次の印に出す。`MachineConfiguration.tokenOwnersReloading`）
    public var owners: @Sendable () -> [String]
    /// GitHub のトークンの期限を問い合わせるもの。nil なら問い合わせない（形だけを確かめる）
    public var githubExpiry: GitHubTokenExpiry?
    /// 管理用のトークンを置いた持ち主（司令塔だけ。`MachineConfiguration.adminTokenOwners`）。空なら自己診断に書かない。
    /// `owners` と同じく、自己診断のたびに呼ぶ（`admin-token` で足した持ち主を次の印に出す）
    public var adminOwners: @Sendable () -> [String]
    /// 管理用のトークンの期限を問い合わせるもの（前に読んだ期限を持ち主ごとに覚えるので、毎日のトークンとは別のもの）。nil なら問い合わせない
    public var adminExpiry: GitHubTokenExpiry?
    /// Claude の setup-token を入れた日の記録（`MachinePaths.claudeTokenRecord`）。nil なら期限を書かない
    public var claudeTokenRecord: URL?
    /// 使っている `claude` の版を測る（人が入れ替えたら次の印で分かるよう、印を書くたびに測る）
    public var claudeVersion: @Sendable () async -> String?
    /// ビルドとテストに使う Xcode の版を測る（xcode-select を切り替えた・Xcode を上げたら次の印で分かるよう、印を書くたびに測る）
    public var xcodeVersion: @Sendable () async -> String?
    public var now: @Sendable () -> Date

    public init(
        secrets: any SecretStore,
        volume: URL,
        owners: @escaping @Sendable () -> [String],
        githubExpiry: GitHubTokenExpiry? = nil,
        adminOwners: @escaping @Sendable () -> [String] = { [] },
        adminExpiry: GitHubTokenExpiry? = nil,
        claudeTokenRecord: URL? = nil,
        claudeVersion: @escaping @Sendable () async -> String? = { nil },
        xcodeVersion: @escaping @Sendable () async -> String? = { nil },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.secrets = secrets
        self.volume = volume
        self.owners = owners
        self.githubExpiry = githubExpiry
        self.adminOwners = adminOwners
        self.adminExpiry = adminExpiry
        self.claudeTokenRecord = claudeTokenRecord
        self.claudeVersion = claudeVersion
        self.xcodeVersion = xcodeVersion
        self.now = now
    }

    public func status() async -> CommanderLoop.MachineStatus {
        let (check, claude, xcode) = (await selfCheck(), await claudeVersion(), await xcodeVersion())
        return CommanderLoop.MachineStatus(
            diskFreeGB: diskFreeGB(), load: load(), selfCheck: check, claudeVersion: claude, xcodeVersion: xcode
        )
    }

    /// Keychain に必要なものがあり、形が合い、期限が切れていないか。値そのものは書かない
    public func selfCheck() async -> SelfCheck {
        await selfCheck(includingAdmin: true)
    }

    /// `includingAdmin` が false なら、管理用のトークンを問い合わせない（上限の残りだけを見るとき）
    private func selfCheck(includingAdmin: Bool) async -> SelfCheck {
        let (now, owners) = (now(), owners())
        let adminOwners = includingAdmin ? adminOwners() : []
        let githubTokens: [SelfCheck.GitHubToken]
        let adminTokens: [SelfCheck.GitHubToken]
        let claude: SelfCheck.State
        do {
            githubTokens = try await githubTokenStates(of: owners, now: now)
            adminTokens = try await adminTokenStates(of: adminOwners, now: now)
            claude = Self.state(of: try secrets.read(.claudeToken)) { $0.hasPrefix(Self.claudeTokenPrefix) }
        } catch {
            return SelfCheck(checkedAt: Timestamp(now), keychain: .invalid, githubToken: .missing, claudeToken: .missing)
        }
        // 前の版で入れた setup-token は、入れた日が分からないので期限を書かない
        let claudeExpiresAt = claude == .missing ? nil : claudeTokenRecord.flatMap(ClaudeTokenRecord.load)?.expiresAt
        return SelfCheck(
            checkedAt: Timestamp(now),
            keychain: .ok,
            githubToken: owners.isEmpty ? .missing : Self.summary(of: githubTokens.map(\.state)),
            claudeToken: claude == .ok && claudeExpiresAt.map { $0.date <= now } == true ? .expired : claude,
            githubTokenExpiresAt: githubTokens.compactMap(\.expiresAt).min(),
            claudeTokenExpiresAt: claudeExpiresAt,
            githubTokens: githubTokens,
            // 管理用のトークンは、無くても毎日の仕事は止まらないので、githubToken のまとめに入れない
            githubAdminTokens: adminOwners.isEmpty ? nil : adminTokens
        )
    }

    /// GitHub の REST の上限の残り（持ち主ごとのトークンで読んだもののうち、一番少ないもの）。読めなければ nil。
    /// 生きている印より短い間隔で呼ぶ（`/rate_limit` は上限に数えられない。Claude と Xcode の版は測らない）
    public func githubRateLimit() async -> GitHubRateLimit? {
        await selfCheck(includingAdmin: false).githubRateLimit
    }

    /// 持ち主ごとのトークンの様子。形の合うトークンだけ、GitHub に期限を問い合わせる
    private func githubTokenStates(of owners: [String], now: Date) async throws(SecretStoreError) -> [SelfCheck.GitHubToken] {
        let tokens = GitHubTokens(secrets: secrets)
        var states: [SelfCheck.GitHubToken] = []
        for owner in owners {
            let state = try tokens.state(of: [owner])
            guard state == .ok, let githubExpiry, let token = try tokens.token(for: owner) else {
                states.append(.init(owner: owner, state: state))
                continue
            }
            states.append(await githubExpiry.check(owner: owner, token: token, now: now))
        }
        return states
    }

    /// 持ち主ごとの管理用のトークンの様子。形の合うトークンだけ、GitHub に期限を問い合わせる。
    /// 上限の残りは毎日のトークンと同じアカウントで数えるので、書かない
    private func adminTokenStates(of owners: [String], now: Date) async throws(SecretStoreError) -> [SelfCheck.GitHubToken] {
        let tokens = GitHubAdminTokens(secrets: secrets)
        var states: [SelfCheck.GitHubToken] = []
        for owner in owners {
            let state = try tokens.state(of: owner)
            guard state == .ok, let adminExpiry, let token = try tokens.token(for: owner) else {
                states.append(.init(owner: owner, state: state))
                continue
            }
            var checked = await adminExpiry.check(owner: owner, token: token, now: now)
            checked.rateLimit = nil
            states.append(checked)
        }
        return states
    }

    /// 持ち主ごとの様子をまとめる。1 つでも無ければ `missing`、次に `invalid`・`expired` の順
    static func summary(of states: [SelfCheck.State]) -> SelfCheck.State {
        [.missing, .invalid, .expired].first { states.contains($0) } ?? .ok
    }

    /// Claude の setup-token の先頭（API キーは `sk-ant-api03-` で、従量課金になるので受け付けない）
    public static let claudeTokenPrefix = "sk-ant-oat01-"

    private static func state(of data: Data?, isValid: (String) -> Bool) -> SelfCheck.State {
        guard let data else { return .missing }
        guard let text = String(bytes: data, encoding: .utf8), isValid(text) else { return .invalid }
        return .ok
    }

    /// 毎回測り直す。URL は読んだ値を覚えているので、同じ URL のまま読むと起動したときの値を返し続ける
    func diskFreeGB() -> Int {
        var url = volume
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)
    }

    private func load() -> Double {
        var averages = [Double](repeating: 0, count: 1)
        return getloadavg(&averages, 1) == 1 ? averages[0] : 0
    }
}
