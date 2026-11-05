import AskHubProtocol
import AskHubStateStore
import Foundation

/// 状態リポジトリに置かれた、まだ処理していない人の意図
public struct PendingIntent: Hashable, Sendable {
    public var device: KeyID
    public var nonce: ULID

    public var path: String { StatePath.intent(device: device, nonce: nonce) }
}

/// 人の意図を 1 つ受け付けた結果
public enum IntakeOutcome: Equatable, Sendable {
    /// 指示として扱った
    case accepted(kind: String)
    /// 署名は合ったが、扱わなかった（理由は処理した記録に書き、クライアントに出す）
    case rejected(kind: String, reason: String)
    /// 署名を確かめられない・形が違う・まだ扱えない種類。処理した記録を作らない
    /// （署名の合わない意図の番号で記録を作ると、本物の意図を使えなくできてしまうため）
    case ignored(reason: String)
}

/// 人の意図の種類ごとの処理。状態リポジトリに書くのは処理だけで、処理した記録は受け付けの側が書く。
///
/// 処理は、同じ意図で 2 度呼ばれても結果が変わらないように書く（記録を書く前に止まると、次の周でもう一度呼ばれる）
public protocol IntentHandler: Sendable {
    func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision
}

public enum IntentDecision: Equatable, Sendable {
    case accept
    case reject(String)
}

/// 人の意図を見張り、確かめ、種類ごとの処理に渡す（`docs/renewal/flows.md` の「司令塔の動き」、`protocol.md` の「確かめること」）
public struct IntentIntake: Sendable {
    public var context: CommanderContext
    /// 信用するアカウントに結びついた、取り消されていない公開鍵（`TrustAnchor.trustedKeys()` から作る）
    public var verifier: IntentVerifier
    public var handlers: [String: any IntentHandler]

    public init(context: CommanderContext, verifier: IntentVerifier, handlers: [String: any IntentHandler]) {
        self.context = context
        self.verifier = verifier
        self.handlers = handlers
    }

    /// まだ処理していない（処理した記録の無い）意図を、`nonce`（時刻の順）に並べる。
    /// 意図と記録は増え続けるので、1 つのディレクトリの一覧の上限（1,000 件）を受けない読み方で、両方を 1 度ずつ並べて比べる
    public func pending() async throws(CommanderError) -> [PendingIntent] {
        let consumed = Set(try await files(under: StatePath.consumedDirectory).compactMap(Self.intent(at:)))
        let found = try await files(under: StatePath.intents).compactMap(Self.intent(at:)).filter { !consumed.contains($0) }
        return found.sorted { $0.nonce < $1.nonce }
    }

    /// `<dir>/<device>/<nonce>.json` から端末と番号を読む。形の違うパスは無いものとして扱う
    static func intent(at path: String) -> PendingIntent? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, let device = KeyID(rawValue: String(parts[1])), parts[2].hasSuffix(".json"),
              let nonce = ULID(rawValue: String(parts[2].dropLast(5))) else {
            return nil
        }
        return PendingIntent(device: device, nonce: nonce)
    }

    /// まだ処理していない意図を、順に 1 つずつ処理する。状態リポジトリに書けなかったら、そこで止める（次の周で続きから）
    public func processPending() async throws(CommanderError) -> [IntakeOutcome] {
        var outcomes: [IntakeOutcome] = []
        for intent in try await pending() {
            outcomes.append(try await process(intent))
        }
        return outcomes
    }

    public func process(_ intent: PendingIntent) async throws(CommanderError) -> IntakeOutcome {
        guard let blob = try await read(intent.path), let value = try? JSONValue(parsing: blob.data) else {
            return .ignored(reason: "読めない")
        }
        let envelope: IntentEnvelope
        do {
            envelope = try verifier.verify(stored: value, now: context.now())
        } catch .expired {
            return try await record(intent, kind: Self.kind(in: value), decision: .reject("有効期間（7 日）を過ぎている"))
        } catch .issuedInFuture {
            return try await record(intent, kind: Self.kind(in: value), decision: .reject("発行の時刻が先すぎる（端末の時計を確かめる）"))
        } catch {
            return .ignored(reason: "署名を確かめられない（\(error)）")
        }
        // 置き場所と封筒が食い違う意図は、別の端末・番号のものとして扱わない
        guard envelope.keyId == intent.device, envelope.nonce == intent.nonce else { return .ignored(reason: "置き場所と封筒が合わない") }
        guard let handler = handlers[envelope.kind] else { return .ignored(reason: "まだ扱えない種類（\(envelope.kind)）") }
        let decision = try await handler.handle(envelope, in: context)
        return try await record(intent, kind: envelope.kind, decision: decision)
    }

    /// 処理した記録を、版なしで作る。すでにあれば（ほかの周で書いた）そのまま
    private func record(_ intent: PendingIntent, kind: String, decision: IntentDecision) async throws(CommanderError) -> IntakeOutcome {
        let file: ConsumedIntentFile
        let outcome: IntakeOutcome
        switch decision {
        case .accept:
            file = ConsumedIntentFile(kind: kind, consumedAt: context.timestamp, result: .accepted)
            outcome = .accepted(kind: kind)
        case let .reject(reason):
            file = ConsumedIntentFile(kind: kind, consumedAt: context.timestamp, result: .rejected, reason: reason)
            outcome = .rejected(kind: kind, reason: reason)
        }
        do {
            try await context.files.create(file, at: StatePath.consumed(device: intent.device, nonce: intent.nonce), message: "人の意図を処理した")
        } catch .alreadyExists {
            return outcome
        } catch {
            throw .files(error)
        }
        return outcome
    }

    private static func kind(in value: JSONValue) -> String {
        value["envelope"]?["kind"]?.stringValue ?? "unknown"
    }

    private func files(under directory: String) async throws(CommanderError) -> [String] {
        do {
            return try await context.store.listFiles(under: directory)?.map(\.path) ?? []
        } catch {
            throw .store(error)
        }
    }

    private func read(_ path: String) async throws(CommanderError) -> StoredBlob? {
        do {
            return try await context.store.read(path)
        } catch {
            throw .store(error)
        }
    }
}
