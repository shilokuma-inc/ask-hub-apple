import AskHubProtocol
import AskHubStateStore
import Foundation

/// この Mac で、片付けの候補を探して書き、人が選んだ候補を消すもの（`LocalCleanupMachine`。テストでは差し替える）
public protocol CleanupMachine: Sendable {
    /// 人が作った clone・Simulator・Xcode の DerivedData を探す。読めなかった場所も返す
    func scan() async -> CleanupScan
    /// 1 つの候補を消す（clone と DerivedData はゴミ箱に移す）。消す前に、まだ候補の決まりに合うかを確かめ直す。
    /// 消せたら nil、消さなかったらその理由
    func remove(_ candidate: CleanupCandidatesFile.Candidate) async -> String?
}

/// 探した結果
public struct CleanupScan: Equatable, Sendable {
    public var candidates: [CleanupCandidatesFile.Candidate]
    /// 読めなかった場所（ホームからのパス）
    public var unreadable: [String]

    public init(candidates: [CleanupCandidatesFile.Candidate], unreadable: [String] = []) {
        self.candidates = candidates
        self.unreadable = unreadable
    }
}

/// 片付けの頼み（`cleanup/<mac>/requests.json`。司令塔が受け付けた人の意図）を、この Mac で済ませる（`docs/renewal/operations.md` の「容量」）。
///
/// 司令塔とワーカーが周ごとに `poll` を呼ぶ。済ませていない頼みがあれば、1 つずつ裏で動かす（探すのは数分かかることがあるので、周を止めない）。
/// 頼みの元の人の意図の署名を自分で確かめ、この Mac 宛てで頼みと中身が合うときだけ動く。
/// 消すのは、自分が探して `candidates.json` に書いた候補の id だけで、選んだ後に探し直していれば何も消さない
public actor CleanupService {
    nonisolated let context: CommanderContext
    nonisolated let machine: any CleanupMachine
    nonisolated let log: @Sendable (String) -> Void
    private var running: Task<Void, Never>?
    /// 済ませたが書けなかった結果。次の周で、頼みをやり直さずに同じ結果を書き直す（消したものを、もう一度消そうとして「消さなかった」と記録しない）
    private var unpublished: CleanupCandidatesFile?
    /// 書けなかった結果を残す手元のファイル。止まって起動し直しても、頼みをやり直さずに書き直す（nil なら手元に残さない）
    nonisolated let journal: URL?

    public init(
        context: CommanderContext,
        machine: any CleanupMachine,
        journal: URL? = nil,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.context = context
        self.machine = machine
        self.journal = journal
        self.log = log
    }

    /// 済ませていない頼みがあり、動いているものが無ければ、古いものから 1 つ動かし始める。読めないときは次の周でやり直す
    public func poll(verifier: IntentVerifier) async {
        guard running == nil else { return }
        if unpublished == nil, let journal {
            // 書き置きがあるのに読めない間も、次の頼みを済ませない（読めるようになった後に、古い書き置きで新しい結果を上書きしない）
            do {
                unpublished = try Self.loadJournal(journal)
            } catch {
                log("片付けの書き置き \(journal.path) を読めなかった（\(error)）。次の頼みを済ませずに次の周でやり直す")
                return
            }
        }
        if let unpublished {
            guard await republish(unpublished) else { return }
            self.unpublished = nil
            // 書き置きを消せないまま次の頼みを済ませると、済ませた記録が上限で落ちた後に、古い書き置きで新しい結果を上書きしてしまう
            guard removeJournal() else {
                log("片付けの書き置きを手元から消せなかったので、次の頼みを済ませずに次の周でやり直す")
                return
            }
        }
        let next: CleanupRequestsFile.Request
        do {
            let path = StatePath.cleanupRequests(context.mac)
            guard let requests = try await context.files.read(CleanupRequestsFile.self, at: path)?.file else { return }
            let current = try await currentFile()
            guard let pending = requests.requests.first(where: { !current.hasHandled($0.intent) }) else { return }
            next = pending
        } catch {
            log("片付けの頼みを読めなかった（\(error)）。次の周でやり直す")
            return
        }
        running = Task {
            await self.handle(next, verifier: verifier)
            await self.finished()
        }
    }

    /// 動いている頼みが終わるまで待つ（テストで使う）
    public func waitForRunning() async {
        await running?.value
    }

    private func finished() {
        running = nil
    }

    /// 結果を書く。書けたら true
    private func publish(_ file: CleanupCandidatesFile) async -> Bool {
        do {
            try await context.put(file, at: StatePath.cleanupCandidates(context.mac), message: "\(context.mac) の片付けの候補")
            return true
        } catch {
            log("片付けの結果を書けなかった（\(error)）。次の周で、同じ結果を書き直す")
            return false
        }
    }

    /// 書けなかった結果を書き直す。書き直せたか、もう書いてあれば true。
    /// 結果を書いた後、手元の書き置きを消す前に止まった（消せなかった）なら、もう書いてあるので書き直さない
    /// （消している間の書き置き「途中で止まった」で、書けた結果を上書きしない）
    private func republish(_ file: CleanupCandidatesFile) async -> Bool {
        if let last = file.handled.last {
            do {
                if try await currentFile().hasHandled(last.intent) { return true }
            } catch {
                log("片付けの候補を読めなかった（\(error)）。次の周で、書けなかった結果を書き直す")
                return false
            }
        }
        return await publish(file)
    }

    /// 頼みを 1 つ済ませ、結果を書く。書けなければ、次の周で頼みをやり直さずに同じ結果を書き直す。
    /// 元の意図を一時的に読めない（GitHub に届かないなど）ときは、済ませたことにせず、次の周でやり直す
    func handle(_ request: CleanupRequestsFile.Request, verifier: IntentVerifier) async {
        let now = context.timestamp
        var file: CleanupCandidatesFile
        do {
            file = try await currentFile()
        } catch {
            log("片付けの候補を読めなかった（\(error)）。次の周でやり直す")
            return
        }
        var record = CleanupCandidatesFile.Handled(intent: request.intent, action: request.action, at: now)
        let originProblem: String?
        do {
            originProblem = try await self.originProblem(of: request, verifier: verifier)
        } catch {
            log("片付けの頼み \(request.intent.nonce) の元の人の意図を読めなかった（\(error)）。次の周でやり直す")
            return
        }
        if let problem = originProblem {
            record.problem = problem
            log("片付けの頼み \(request.intent.nonce) を済ませなかった: \(problem)")
        } else {
            switch request.action {
            case .find:
                let scan = await machine.scan()
                file.scannedAt = context.timestamp
                let largestFirst = scan.candidates.sorted { ($0.bytes, $1.id) > ($1.bytes, $0.id) }
                file.candidates = Array(largestFirst.prefix(CleanupCandidatesFile.maximumCandidates))
                file.unreadable = scan.unreadable.isEmpty ? nil : scan.unreadable
                record.at = context.timestamp
                log("片付けの候補を \(file.candidates.count) 件見つけた（読めなかった場所 \(scan.unreadable.count) か所）")
            case .remove:
                // 消し始める前に、途中で止まったときの結果を手元に書いておく。起動し直したらそれを書き、頼みをやり直さない
                // （どれを消したか分からないまま、同じ頼みで消し直さない）。書けなければ消し始めず、次の周でやり直す
                var interrupted = record
                interrupted.problem = Self.interruptedProblem
                guard saveJournal(Self.appending(interrupted, to: file)) else {
                    log("片付けの頼み \(request.intent.nonce) の書き置きを手元に残せなかったので、消し始めずに次の周でやり直す")
                    return
                }
                await remove(request, from: &file, into: &record)
            }
        }
        file = Self.appending(record, to: file)
        if await publish(file) {
            // 消せなければ、次の周で消し直すまで次の頼みを済ませない（`poll`）
            _ = removeJournal()
        } else {
            unpublished = file
            // 起動し直しても書き直せるよう、手元に残す（残せなくても、動いている間は書き直す）
            _ = saveJournal(file)
        }
    }

    /// 消している途中で止まったときに書く理由
    static let interruptedProblem = "消している途中で止まったので、どれを消したか分からない。探し直してください"

    /// 済ませた記録を足す（古いものから落とす）
    static func appending(_ record: CleanupCandidatesFile.Handled, to file: CleanupCandidatesFile) -> CleanupCandidatesFile {
        var file = file
        file.handled = Array((file.handled + [record]).suffix(CleanupCandidatesFile.keptHandled))
        return file
    }

    /// 手元の書き置き。無ければ nil。あるのに読めない（書き置きのフォルダに入れない・形が違うなど）ときは投げる
    static func loadJournal(_ url: URL) throws -> CleanupCandidatesFile? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try StateFileCoder.decode(CleanupCandidatesFile.self, from: data)
    }

    /// 手元の書き置きを消す。もう無い（手元に残さない設定も）なら true
    private func removeJournal() -> Bool {
        guard let journal else { return true }
        try? FileManager.default.removeItem(at: journal)
        return !FileManager.default.fileExists(atPath: journal.path)
    }

    /// 手元のファイルに書く。手元に残さない設定なら、書かずに true
    private func saveJournal(_ file: CleanupCandidatesFile) -> Bool {
        guard let journal else { return true }
        do {
            try StateFileCoder.encode(file).write(to: journal, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 選んだ候補を消す。選んだ後に探し直していれば、選んだものと今の候補が違うかもしれないので、何も消さない
    private func remove(
        _ request: CleanupRequestsFile.Request,
        from file: inout CleanupCandidatesFile,
        into record: inout CleanupCandidatesFile.Handled
    ) async {
        guard let scannedAt = request.scannedAt, scannedAt == file.scannedAt else {
            record.problem = "選んだ後に探し直したので、何も消さなかった。もう一度選んでください"
            return
        }
        var removed: [String] = []
        var skipped: [CleanupSkip] = []
        for id in request.candidates ?? [] {
            guard let candidate = file.candidates.first(where: { $0.id == id }) else {
                skipped.append(.init(id: id, reason: "候補に無い（もう消した・探し直した）"))
                continue
            }
            // 候補のファイルの場所だけが書き換えられていれば、選んだ id のまま別の場所を消さない
            guard candidate.isBoundToLocation else {
                skipped.append(.init(id: id, reason: "候補の場所が、探したときの id と合わないので消さなかった"))
                continue
            }
            if let caution = candidate.caution {
                skipped.append(.init(id: id, reason: "\(caution)ので消さなかった"))
            } else if let reason = await machine.remove(candidate) {
                skipped.append(.init(id: id, reason: reason))
            } else {
                removed.append(id)
            }
        }
        file.candidates.removeAll { removed.contains($0.id) }
        record.removed = removed
        record.skipped = skipped.isEmpty ? nil : skipped
        record.at = context.timestamp
        log("片付けの候補を \(removed.count) 件消した（消さなかったもの \(skipped.count) 件）")
    }

    /// 頼みの元の人の意図が、署名を確かめられ、この Mac 宛てで、頼みと中身が合うか。合わなければその理由（確かに断れるものだけ）。
    /// 一時的に読めないときは投げる（済ませたことにしない）
    private func originProblem(of request: CleanupRequestsFile.Request, verifier: IntentVerifier) async throws(CommanderError) -> String? {
        let envelope = try await context.envelope(of: request.intent, verifier: verifier)
        guard let envelope else { return "元の人の意図が無い・署名を確かめられない" }
        do {
            switch request.action {
            case .find:
                let find = try FindCleanupCandidatesIntent(envelope: envelope)
                guard find.mac == context.mac else { return "元の人の意図がこの Mac 宛てでない" }
            case .remove:
                let remove = try RemoveCleanupCandidatesIntent(envelope: envelope)
                guard remove.mac == context.mac else { return "元の人の意図がこの Mac 宛てでない" }
                guard remove.candidates == request.candidates, remove.scannedAt == request.scannedAt else {
                    return "頼みの中身が元の人の意図と違う"
                }
            }
        } catch {
            return "元の人の意図の形が頼みと違う（\(error.detail)）"
        }
        return nil
    }

    /// 自分が書いた候補のファイル。まだ無ければ空
    private func currentFile() async throws(StateFileStore.Failure) -> CleanupCandidatesFile {
        try await context.files.read(CleanupCandidatesFile.self, at: StatePath.cleanupCandidates(context.mac))?.file
            ?? CleanupCandidatesFile(mac: context.mac)
    }
}
