import Foundation

// Claude の利用上限（解除の時刻まで、ループの起動・再開を止める）
extension Orchestrator {
    /// 利用上限で待機しているなら、解除の時刻
    func activeUsageLimit(at date: Date) -> Date? {
        guard let usageLimitedUntil, usageLimitedUntil > date else {
            return nil
        }
        return usageLimitedUntil
    }

    /// 止まったループの最新のログから、利用上限の解除の時刻を読み直す
    func refreshUsageLimit(statuses: [String: LoopStatus]) async {
        let current = now()
        var latest = activeUsageLimit(at: current)
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            let status = statuses[key] ?? .idle
            guard !status.processAlive, status.stateFileExists == false,
                  let reset = await runtime.usageLimitReset(of: repository) else {
                continue
            }
            // 上限で止まった分は、自動の再開・起動の失敗に数えない（解除の時刻を過ぎてから気付いた場合も。
            // 最新のログは次の起動で別のファイルになるので、免除し続けることはない）
            stallWatcher.forget(repositoryKey: key)
            tracker.forgiveFailures(repositoryKey: key)
            if reset > current {
                latest = max(latest ?? reset, reset)
            }
        }
        updateUsageLimit(latest)
    }

    /// コマンドの出力が利用上限で終わっていれば、解除の時刻を覚えて `true`
    func recordUsageLimit(in output: String) -> Bool {
        let current = now()
        guard let reset = UsageLimit.resetDate(in: output, loggedAt: current), reset > current else {
            return false
        }
        updateUsageLimit(max(reset, activeUsageLimit(at: current) ?? reset))
        return true
    }

    private func updateUsageLimit(_ until: Date?) {
        guard until != usageLimitedUntil else {
            return
        }
        usageLimitedUntil = until
        // アプリの表示がすぐ変わるよう、担当の印を書き直す
        lastHeartbeats.removeAll()
        if let until {
            log("Claude の利用上限に達しているので、\(until.formatted(.iso8601)) までループの起動・再開を止めます")
        } else {
            log("Claude の利用上限が解除されたので、ループの起動・再開を再開します")
        }
    }
}
