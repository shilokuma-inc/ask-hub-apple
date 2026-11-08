import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 状態リポジトリ（`docs/renewal/protocol.md`）の窓口。
///
/// 読むのは状態リポジトリだけ（各リポジトリの Discussion・PR は読まない）。人の意図は、この端末の鍵で署名して `intents/` に置く。
/// 司令塔は 30 秒ほどの間隔で意図を処理するので、送った後の取り直しでは、処理を待つ意図を送った結果として先に出す
final class StateClientService: ClientService {
    /// 司令塔が意図を見る間隔に合わせる。変わっていないファイルは ETag で読むので、GitHub の上限に数えられない
    let refreshInterval: Duration = .seconds(30)

    /// 状態リポジトリへの同時の要求の上限。並べて読むので、GitHub の 2 次のレート制限（同時の要求が多いと 403・429）に当たらないよう抑える
    static let concurrentRequests = 8

    private let store: any StateStore
    /// 送った意図と処理の記録（書いたら変わらない）の読んだ中身。取り直しのたびに読み直さない
    private let immutables = ImmutableFileCache()
    private let key: DeviceSigningKey
    private let now: @Sendable () -> Date
    /// 送るたびに使い回す（意図の番号を送った順に大きくする。司令塔は番号の順に処理するので、判断に答えてから承認する、などの順を守る）
    private let sender: IntentSender
    private var index = StateIndex()
    /// 最後に読んだ、この端末が送った意図
    private var readSends: [SentDraft] = []
    /// 送った後の読み込みに、まだ出ていない意図
    private var unreadSends: [SentDraft] = []

    /// 送った意図の中身と、司令塔がまだ受け取っていないか
    private struct SentDraft {
        var nonce: ULID
        var draft: IntentDraft
        var sentAt: Date
        var isWaiting: Bool
    }

    init(store: any StateStore, key: DeviceSigningKey, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = ConcurrencyLimitedStore(store, limit: Self.concurrentRequests)
        self.key = key
        self.now = now
        sender = IntentSender(store: self.store, key: key, now: now)
    }

    func fetchSnapshot() async throws -> ClientSnapshot {
        let documents: StateDocuments
        do {
            documents = try await StateReader(store: store, device: key.keyID, immutables: immutables).read()
        } catch {
            throw ClientServiceError(message: StateServiceError.message(for: error))
        }
        let date = now()
        let built = StateSnapshotBuilder(documents: documents, now: date).build()
        index = built.index
        readSends = documents.sentIntents.map { sent in
            let sentAt = sent.envelope.issuedAt.date
            let isWaiting = sent.consumed == nil && date.timeIntervalSince(sentAt) < StateSnapshotBuilder.intentLifetime
            return SentDraft(nonce: sent.envelope.nonce, draft: IntentDraft(sent.envelope), sentAt: sentAt, isWaiting: isWaiting)
        }
        unreadSends.removeAll { unread in readSends.contains { $0.nonce == unread.nonce } }
        return built.snapshot
    }

    /// 送る。まとめて OK のように 1 つの操作が複数の意図になるときは、順に送り、控えには最後に送ったものを返す
    /// （途中で失敗したら、送れた分は送ったまま失敗を返す。もう一度送ると、残りだけを送る）
    @discardableResult
    func perform(_ intent: HumanIntent) async throws -> SendReceipt {
        var drafts = try StateIntentMapper(index: index).drafts(for: intent)
        if drafts.count > 1 {
            // 送ってあって司令塔がまだ受け取っていないものは送り直さない（同じカードへの答え直しは断られる）
            drafts.removeAll { draft in (readSends + unreadSends).contains { $0.draft == draft && $0.isWaiting } }
        }
        var receipt = SendReceipt()
        for draft in drafts {
            let reference: IntentReference
            do {
                reference = try await sender.send(draft)
            } catch {
                throw ClientServiceError(message: StateServiceError.message(for: error))
            }
            // 次に読むまでの間も、送ったことを覚えておく（読んだ中に出たら、読んだものに任せる）
            unreadSends.append(SentDraft(nonce: reference.nonce, draft: draft, sentAt: now(), isWaiting: true))
            let epicID = draft.kind == RequestIntent.kind ? RequestIntent.epicID(for: reference).rawValue : nil
            receipt = SendReceipt(requestedEpicID: epicID, intentID: reference.nonce.rawValue)
        }
        return receipt
    }

    func supports(_ intent: HumanIntent) -> Bool {
        StateIntentMapper(index: index).supports(intent)
    }

    /// 送る形（対象の版は最後に読んだ状態から取る）が同じ意図のうち、最後に送ったもの。複数の意図になる操作は、すべてを送ってあるときだけ返し、
    /// 1 つでも司令塔がまだ受け取っていなければ受け取り待ちとする
    func lastSend(of intent: HumanIntent) -> SentRecord? {
        guard let drafts = try? StateIntentMapper(index: index).drafts(for: intent) else {
            return nil
        }
        let records = drafts.map { draft in
            (readSends + unreadSends).filter { $0.draft == draft }.max { $0.sentAt < $1.sentAt }
        }
        guard !records.isEmpty, records.allSatisfy({ $0 != nil }) else {
            return nil
        }
        let sent = records.compactMap(\.self)
        return SentRecord(sentAt: sent.map(\.sentAt).max() ?? now(), isWaiting: sent.contains(where: \.isWaiting))
    }
}

private extension IntentDraft {
    /// 送った封筒の中身（番号・時刻・鍵を除いたもの）
    init(_ envelope: IntentEnvelope) {
        self.init(
            kind: envelope.kind,
            repo: envelope.repo,
            target: envelope.target,
            targetVersion: envelope.targetVersion,
            payload: envelope.payload ?? [:]
        )
    }
}

/// 状態リポジトリの読み書きの失敗を、画面に出す文にする。トークンの値やパスの中身は入れない
enum StateServiceError {
    static func message(for error: StateStoreError) -> String {
        switch error {
        case .unauthorized:
            "GitHub のトークンが無効か、期限が切れています。設定で入れ直してください"

        case .tokenUnavailable:
            "GitHub のトークンがありません。設定で入れてください"

        case .forbidden, .notFound:
            "状態リポジトリを読めません。トークンが状態リポジトリの Contents を読み書きできるか確かめてください"

        case .rateLimited(let retryAfter), .budgetExhausted(let retryAfter):
            "GitHub の上限に達しました。\(Int(retryAfter.components.seconds)) 秒ほど待ってからやり直してください"

        case .serverError:
            "GitHub が応答しません。しばらくしてからやり直してください"

        case .transport:
            "通信できませんでした。ネットワークを確かめてください"

        case .conflict:
            "ほかの書き込みとぶつかりました。もう一度送ってください"

        case .redirected:
            "状態リポジトリが移されたか、名前が変わっています。設定で確かめてください"

        case .wrongKind, .invalidPath, .unexpected, .cancelled:
            "状態リポジトリを読み書きできませんでした"
        }
    }

    static func message(for error: ClientError) -> String {
        switch error {
        case .store(let error):
            message(for: error)

        case .signing:
            "この端末の鍵で署名できませんでした。端末のロックを解除してからやり直してください"

        case .ledger, .malformed:
            "送る形を作れませんでした"
        }
    }
}
