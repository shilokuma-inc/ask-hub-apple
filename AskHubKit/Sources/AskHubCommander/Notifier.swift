import AskHubProtocol
import AskHubStateStore
import Foundation

/// 進行を止めているもの（`Blocker`）を、まだ知らせていなければ、登録された端末（`devices/`）に送る（`docs/renewal/operations.md` の「通知」）。
///
/// 二重に送らないよう、送る前に `notifications.json` へ出来事の key を書く（書けなければ送らない）。どの端末にも届かず、
/// 送り直せる失敗だったときだけ記録から外し、間を空けて送り直す。送る途中で司令塔が落ちたときは送り直さない（二重より取りこぼしを選ぶ）
public actor Notifier {
    public struct Settings: Sendable {
        /// ジョブを持った Mac が、これより長く戻らなければ知らせる（MacBook を閉じるたびには知らせない）
        public var macOfflineAfter: Duration
        /// 出来事が無くなってから記録を残す期間。GitHub の障害で一覧が空に見えた周に記録を消して知らせ直さないよう、すぐには消さない
        public var retention: Duration
        /// どの端末にも送れなかったときの待ち。続いた回数ごとに長くする
        public var retryWaits: [Duration]
        /// 通知の文に書く時刻の時間帯（司令塔の Mac の時間帯）
        public var timeZone: TimeZone

        public init(
            macOfflineAfter: Duration = .seconds(60 * 60),
            retention: Duration = .seconds(7 * 24 * 60 * 60),
            retryWaits: [Duration] = [.seconds(60), .seconds(120), .seconds(300), .seconds(600), .seconds(1_800)],
            timeZone: TimeZone = .current
        ) {
            self.macOfflineAfter = macOfflineAfter
            self.retention = retention
            self.retryWaits = retryWaits
            self.timeZone = timeZone
        }
    }

    nonisolated let context: CommanderContext
    nonisolated let sender: any PushSender
    nonisolated let settings: Settings
    nonisolated let log: @Sendable (String) -> Void

    /// 送り直しを待つ時刻（どの端末にも送れなかったとき）
    private var retryAt: Date?
    private var failures = 0
    /// 最後に出した「送らずに待つ」理由（同じ理由を周ごとに出さない）
    private var waiting: String?

    public init(
        context: CommanderContext,
        sender: any PushSender,
        settings: Settings = Settings(),
        log: @escaping @Sendable (String) -> Void
    ) {
        self.context = context
        self.sender = sender
        self.settings = settings
        self.log = log
    }

    /// 1 周。`epics` と `jobs` は `JobSweep` で見直した後のもの、`trusted` は確かめた公開鍵の id（取り消した端末には送らない）、
    /// `rateLimit` は司令塔が読んだ GitHub の REST の上限の残り（読めなければ nil）。送って記録に残した通知を返す
    @discardableResult
    public func notify(
        epics: [EpicFile],
        jobs: [JobFile],
        trusted: Set<KeyID>,
        rateLimit: GitHubRateLimit? = nil
    ) async throws(CommanderError) -> [PushNotice] {
        let now = context.now()
        if let retryAt, now < retryAt { return [] }
        let scan = BlockerScan(context: context, macOfflineAfter: settings.macOfflineAfter)
        let blockers = try await scan.scan(epics: epics, jobs: jobs, rateLimit: rateLimit)
        guard !blockers.isEmpty else { return [] }
        let ledger: NotificationsFile?
        do {
            ledger = try await context.files.read(NotificationsFile.self, at: StatePath.notifications)?.file
        } catch let .unreadable(path, error) {
            wait("\(path) を読めない（\(error)）。何を知らせたか分からないので送らない")
            return []
        } catch {
            throw .files(error)
        }
        let sent = Set(ledger?.sent.map(\.key) ?? [])
        var seen = Set<String>()
        let fresh = blockers.filter { !sent.contains($0.key) && seen.insert($0.key).inserted }
        guard !fresh.isEmpty else { return [] }
        let devices = try await devices(trusted: trusted)
        guard !devices.isEmpty else {
            wait("通知の宛先（devices/ の登録済みの端末）が無いので、知らせずに待つ")
            return []
        }
        waiting = nil
        try await record(fresh.map(\.key), current: Set(blockers.map(\.key)), exists: ledger != nil, now: now)
        var settled: [PushNotice] = []
        var unsent: Set<String> = []
        for notice in PushNotice.compose(fresh, epics: epics, now: now, timeZone: settings.timeZone) {
            if await deliver(notice, to: devices) {
                settled.append(notice)
            } else {
                unsent.formUnion(notice.keys)
            }
        }
        try await retryLater(unsent, now: now)
        return settled
    }

    /// すべての端末に送る。記録に残してよい（どこかに届いた・宛先が使えないだけで送り直しても届かない）なら true
    private func deliver(_ notice: PushNotice, to devices: [DeviceFile]) async -> Bool {
        var results: [PushDelivery] = []
        for device in devices {
            let result = await sender.send(notice, to: device)
            if result != .delivered { log("通知「\(notice.title)」を端末 \(device.device) に送れなかった（\(result)）") }
            results.append(result)
        }
        let retryable = results.contains { if case .failed = $0 { true } else { false } }
        return results.contains(.delivered) || !retryable
    }

    /// どの端末にも送れなかった出来事を記録から外し、間を空けてから送り直す（続いた回数ごとに待ちを長くする）
    private func retryLater(_ keys: Set<String>, now: Date) async throws(CommanderError) {
        guard !keys.isEmpty else {
            failures = 0
            retryAt = nil
            return
        }
        let waits = settings.retryWaits
        let wait = waits.isEmpty ? Duration.seconds(60) : waits[min(failures, waits.count - 1)]
        failures += 1
        retryAt = now.addingTimeInterval(Double(wait.components.seconds))
        try await forget(keys)
    }

    /// 送らずに待つ理由を、変わったときだけ出す
    private func wait(_ reason: String) {
        guard reason != waiting else { return }
        waiting = reason
        log(reason)
    }

    /// 登録された端末のうち、確かめた公開鍵の端末。読めない（知らない版など）宛先と、ファイルの名前と中の id が違う宛先は使わない
    private func devices(trusted: Set<KeyID>) async throws(CommanderError) -> [DeviceFile] {
        let entries: [DirectoryEntry]
        do {
            entries = try await context.store.listAll(StatePath.devices) ?? []
        } catch {
            throw .store(error)
        }
        var devices: [DeviceFile] = []
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
            do {
                guard let device = try await context.files.read(DeviceFile.self, at: entry.path)?.file,
                      entry.path == StatePath.device(device.device), trusted.contains(device.device) else { continue }
                devices.append(device)
            } catch .unreadable {
                continue
            } catch {
                throw .files(error)
            }
        }
        return devices
    }

    /// 送る前に、出来事を記録に足す。今は続いていない出来事のうち、残す期間を過ぎたものは消す
    private func record(_ keys: [String], current: Set<String>, exists: Bool, now: Date) async throws(CommanderError) {
        let at = Timestamp(now)
        let retention = Double(settings.retention.components.seconds)
        let message = "通知した出来事を記録する"
        do {
            guard exists else {
                let file = NotificationsFile(sent: keys.map { .init(key: $0, at: at) })
                try await context.files.create(file, at: StatePath.notifications, message: message)
                return
            }
            try await context.files.update(NotificationsFile.self, at: StatePath.notifications, message: message) { file in
                file.sent.removeAll { !current.contains($0.key) && now.timeIntervalSince($0.at.date) > retention }
                let known = Set(file.sent.map(\.key))
                file.sent += keys.filter { !known.contains($0) }.map { .init(key: $0, at: at) }
                return true
            }
        } catch .alreadyExists {
            throw .changedWhileProcessing(StatePath.notifications)
        } catch {
            throw .files(error)
        }
    }

    /// どの端末にも送れなかった出来事を記録から外し、次に送り直せるようにする
    private func forget(_ keys: Set<String>) async throws(CommanderError) {
        do {
            try await context.files.update(NotificationsFile.self, at: StatePath.notifications, message: "送れなかった通知を記録から外す") { file in
                let count = file.sent.count
                file.sent.removeAll { keys.contains($0.key) }
                return file.sent.count != count
            }
        } catch {
            throw .files(error)
        }
    }
}
