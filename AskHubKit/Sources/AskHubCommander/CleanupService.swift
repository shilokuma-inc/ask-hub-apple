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

    public init(context: CommanderContext, machine: any CleanupMachine, log: @escaping @Sendable (String) -> Void) {
        self.context = context
        self.machine = machine
        self.log = log
    }

    /// 済ませていない頼みがあり、動いているものが無ければ、古いものから 1 つ動かし始める。読めないときは次の周でやり直す
    public func poll(verifier: IntentVerifier) async {
        guard running == nil else { return }
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

    /// 頼みを 1 つ済ませ、結果を書く。書けなければ次の周で同じ頼みをやり直す（探すのはやり直しても同じ。消したものは、次は候補に無いので消さない）
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
        if let problem = await originProblem(of: request, verifier: verifier) {
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
                await remove(request, from: &file, into: &record)
            }
        }
        file.handled = Array((file.handled + [record]).suffix(CleanupCandidatesFile.keptHandled))
        do {
            try await context.put(file, at: StatePath.cleanupCandidates(context.mac), message: "\(context.mac) の片付けの候補")
        } catch {
            log("片付けの結果を書けなかった（\(error)）。次の周でやり直す")
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

    /// 頼みの元の人の意図が、署名を確かめられ、この Mac 宛てで、頼みと中身が合うか。合わなければその理由
    private func originProblem(of request: CleanupRequestsFile.Request, verifier: IntentVerifier) async -> String? {
        let envelope: IntentEnvelope?
        do {
            envelope = try await context.envelope(of: request.intent, verifier: verifier)
        } catch {
            return "元の人の意図を読めない（\(error)）"
        }
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
