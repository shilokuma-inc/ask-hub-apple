import AskHubClient
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 状態リポジトリ（`docs/renewal/protocol.md`）の窓口。
///
/// 読むのは状態リポジトリだけ（各リポジトリの Discussion・PR は読まない）。人の意図は、この端末の鍵で署名して `intents/` に置く。
/// 司令塔は 30 秒ほどの間隔で意図を処理するので、処理を待つ意図・送っている途中の意図・送り終えて読み直す前の意図は、送った結果として先に出す
final class StateClientService: ClientService {
    /// 司令塔が意図を見る間隔に合わせる。読むだけの写しから読むので、変わっていなければ直下の一覧の 1 回（ETag の 304。GitHub の上限に数えられない）で済む
    let refreshInterval: Duration = .seconds(30)
    /// 受け付けの記録を確かめる間隔。記録が無い間の読み取り（404）は GitHub の上限に数えられるので、司令塔の受け取りを待つ意図の 1 つだけを確かめる
    let receiptCheckInterval: Duration? = .seconds(4)

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
    /// 最後に読んだ状態（送り終えていない意図を当てた形を組み立て直すのに使う）
    private var documents: StateDocuments?
    /// 処理を待っていたのを、受け付けたと読んだばかりの意図と、そのとき始めてあった読み込みの最後の番号。
    /// それより後に始めた読み込みでは状態に反映されているので、当てるのをやめる（`StateSnapshotBuilder.justAccepted`）
    private var justAccepted: [ULID: Int] = [:]
    /// 最後に読んだ、この端末が送った意図
    private var readSends: [SentDraft] = []
    /// 送った後の読み込みに、まだ出ていない意図
    private var unreadSends: [SentDraft] = []
    /// 読んだスクショ（パス → 中身）。パスはコミットと画面で決まり、同じパスの中身は変わらないので、読み直さない
    private var screenshots: [String: Data] = [:]
    /// 読んだアプリのアイコン（画像の blob の sha → 中身）と、端末にしまったもの
    private var appIcons: [String: Data] = [:]
    private let appIconCache: AppIconCache
    /// 読んでいるアプリのアイコン（パスと版 → 読み込み）。同じアイコンを並べて出すときに、1 回だけ読む
    private var appIconLoads: [String: Task<StoredBlob?, any Error>] = [:]
    /// 読み始めた数と、送る形の引き当て（`index`）に当てた最後の読み込みの番号。
    /// 後に始めた読み込みが先に終わったら、先に始めた古い読み込みでは引き当てを戻さない（ストアも古い中身を画面に当てない。`ClientStore.refresh`）
    private var startedReads = 0
    private var appliedRead = 0

    /// 送った意図の中身と、司令塔がまだ受け取っていないか
    private struct SentDraft {
        var nonce: ULID
        var draft: IntentDraft
        var sentAt: Date
        var isWaiting: Bool
    }

    init(
        store: any StateStore,
        key: DeviceSigningKey,
        appIconCache: AppIconCache = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = ConcurrencyLimitedStore(store, limit: Self.concurrentRequests)
        self.key = key
        self.appIconCache = appIconCache
        self.now = now
        sender = IntentSender(store: self.store, key: key, now: now)
    }

    func fetchSnapshot() async throws -> ClientSnapshot {
        startedReads += 1
        let generation = startedReads
        let documents: StateDocuments
        do {
            // 読むだけの写しから読む。直下の一覧だけを ETag つきで読み、その下は前に読んだ tree と blob を sha で使い回すので、
            // 終わった epic が増えても、変わっていない取り直しの要求は増えない。無いファイルも tree で分かるので、404 を受けない
            let snapshot = try await store.snapshot()
            documents = try await StateReader(store: snapshot, device: key.keyID, immutables: immutables).read()
        } catch {
            throw ClientServiceError(message: StateServiceError.message(for: error))
        }
        let date = now()
        guard generation > appliedRead else {
            // 後に始めた読み込みがもう当ててあるので、引き当ても当てる意図も戻さない（ストアもこの中身を画面に当てない）
            return StateSnapshotBuilder(documents: documents, now: date).build().snapshot
        }
        appliedRead = generation
        let waiting = Set((readSends + unreadSends).filter(\.isWaiting).map(\.nonce))
        readSends = documents.sentIntents.map { sent in
            let sentAt = sent.envelope.issuedAt.date
            let isWaiting = sent.consumed == nil && date.timeIntervalSince(sentAt) < StateSnapshotBuilder.intentLifetime
            return SentDraft(nonce: sent.envelope.nonce, draft: IntentDraft(sent.envelope), sentAt: sentAt, isWaiting: isWaiting)
        }
        unreadSends.removeAll { unread in readSends.contains { $0.nonce == unread.nonce } }
        // 処理を待っていた意図を受け付けたと読んだら、この後に始める読み込みが終わるまで当て続ける（状態が古いまま読んだかもしれない）
        justAccepted = justAccepted.filter { generation <= $0.value }
        for sent in documents.sentIntents where sent.consumed?.result == .accepted && waiting.contains(sent.envelope.nonce) {
            justAccepted[sent.envelope.nonce] = startedReads
        }
        self.documents = documents
        let built = builder(documents, now: date).build()
        index = built.index
        return built.snapshot
    }

    func snapshot(overlaying intents: [HumanIntent]) -> ClientSnapshot? {
        guard let documents else {
            return nil
        }
        let date = now()
        // 後の意図は、前の意図を当てた後の引き当てで送る形にする（まとめて OK の後のマージの承認など）
        var drafts: [IntentDraft] = []
        var index = index
        for (offset, intent) in intents.enumerated() {
            guard let mapped = try? StateIntentMapper(index: index).drafts(for: intent) else {
                continue
            }
            drafts += mapped
            if offset < intents.count - 1 {
                index = builder(documents, now: date, pending: drafts).build().index
            }
        }
        return builder(documents, now: date, pending: drafts).build().snapshot
    }

    func hasReceipt(for intentID: String) async throws -> Bool {
        guard let nonce = ULID(rawValue: intentID) else {
            return false
        }
        do {
            return try await store.read(StatePath.consumed(device: key.keyID, nonce: nonce)) != nil
        } catch {
            throw ClientServiceError(message: StateServiceError.message(for: error), retryAfter: error.retryAfter)
        }
    }

    /// 最後に読んだ状態を組み立てる。送り終えて読み直す前の意図と、送り終えていない意図（`pending`。押した順）も、送った結果として当てる
    private func builder(_ documents: StateDocuments, now date: Date, pending: [IntentDraft] = []) -> StateSnapshotBuilder {
        let read = Set(documents.sentIntents.map(\.envelope.nonce))
        let unread = unreadSends.filter { !read.contains($0.nonce) }.map { envelope($0.draft, nonce: $0.nonce, at: $0.sentAt) }
        // 送り終えていない意図には、まだ番号が無い。当てる順を決めるだけの仮の番号を、送り終えた意図より後の時刻で付ける
        let unsent = pending.enumerated().map { offset, draft in
            envelope(draft, nonce: ULID.generate(at: date.addingTimeInterval(Double(offset))), at: date)
        }
        return StateSnapshotBuilder(
            documents: documents,
            now: date,
            unread: (unread + unsent).reversed(),
            justAccepted: Set(justAccepted.keys)
        )
    }

    private func envelope(_ draft: IntentDraft, nonce: ULID, at date: Date) -> IntentEnvelope {
        IntentEnvelope(
            kind: draft.kind,
            repo: draft.repo,
            target: draft.target,
            targetVersion: draft.targetVersion,
            payload: draft.payload,
            issuedAt: Timestamp(date),
            nonce: nonce,
            keyId: key.keyID
        )
    }

    /// 送る形の引き当てを、送り終えて読み直す前の意図を当てた後のものにする（続けて送る意図が、前の意図を踏まえて送れるように）
    private func rebuildIndex() {
        if let documents {
            index = builder(documents, now: now()).build().index
        }
    }

    /// 送る。まとめて OK のように 1 つの操作が複数の意図になるときは、順に送り、控えには送ったものすべてを返す
    /// （途中で失敗したら、送れた分は送ったまま失敗を返す。もう一度送ると、残りだけを送る）
    @discardableResult
    func perform(_ intent: HumanIntent) async throws -> SendReceipt {
        var drafts = try StateIntentMapper(index: index).drafts(for: intent)
        if drafts.count > 1 {
            // 送ってあって司令塔がまだ受け取っていないものは送り直さない（同じカードへの答え直しは断られる）
            drafts.removeAll { draft in (readSends + unreadSends).contains { $0.draft == draft && $0.isWaiting } }
        }
        // 渡すファイルの中身は、意図より先に置く（司令塔は意図を読んでから中身を読む）
        let attachments = StateIntentMapper.attachments(for: intent)
        var receipt = SendReceipt()
        for draft in drafts {
            let reference: IntentReference
            do {
                reference = try await sender.send(draft, attachments: attachments)
            } catch {
                // 書けた分は司令塔が受け取るので、控えを添えて失敗を返す（反映中として追い続ける）
                let sent = receipt.sent.isEmpty ? nil : receipt
                rebuildIndex()
                throw ClientServiceError(message: StateServiceError.message(for: error), sentBeforeFailure: sent)
            }
            // 次に読むまでの間も、送ったことを覚えておく（読んだ中に出たら、読んだものに任せる）
            unreadSends.append(SentDraft(nonce: reference.nonce, draft: draft, sentAt: now(), isWaiting: true))
            var target = StateSnapshotBuilder.target(kind: draft.kind, repo: draft.repo, target: draft.target)
            if draft.kind == RequestIntent.kind {
                let epicID = RequestIntent.epicID(for: reference).rawValue
                receipt.requestedEpicID = epicID
                target = .request(epicID: epicID)
            }
            receipt.sent.append(SendReceipt.Sent(id: reference.nonce.rawValue, target: target))
        }
        rebuildIndex()
        return receipt
    }

    func supports(_ intent: HumanIntent) -> Bool {
        StateIntentMapper(index: index).supports(intent)
    }

    /// 判断のカードのスクショを状態リポジトリから読む。epic の `screenshots/` の下の PNG だけを読む
    func screenshot(at path: String) async throws -> Data {
        if let data = screenshots[path] { return data }
        guard DecisionsFile.isScreenshotPath(path) else { throw ClientServiceError(message: "スクショのパスの形が違う") }
        let blob: StoredBlob?
        do {
            blob = try await store.read(path)
        } catch {
            throw ClientServiceError(message: StateServiceError.message(for: error))
        }
        guard let data = blob?.data else { throw ClientServiceError(message: "スクショが状態リポジトリに無い") }
        screenshots[path] = data
        return data
    }

    /// 対象のアプリのアイコンを読む。読んだもの・端末にしまったものがあれば、状態リポジトリを読まない。
    /// `repos/<owner>/<repo>/icon.png` だけを読む
    func appIcon(at path: String, version: String) async throws -> Data {
        if let data = appIcons[version] ?? appIconCache.data(for: version) {
            appIcons[version] = data
            return data
        }
        guard Self.isAppIconPath(path) else { throw ClientServiceError(message: "アプリのアイコンのパスの形が違う") }
        let key = "\(path)@\(version)"
        let store = store
        let loading = appIconLoads[key] ?? Task { try await store.read(path) }
        appIconLoads[key] = loading
        defer { appIconLoads[key] = nil }
        let blob: StoredBlob?
        do {
            blob = try await loading.value
        } catch let error as StateStoreError {
            throw ClientServiceError(message: StateServiceError.message(for: error))
        } catch {
            throw ClientServiceError(message: error.localizedDescription)
        }
        guard let blob else { throw ClientServiceError(message: "アプリのアイコンが状態リポジトリに無い") }
        // repo.json と画像の書き込みの間に読んだときは、中身が版と違うので、端末にはしまわない
        if blob.sha == version {
            appIcons[version] = blob.data
            appIconCache.store(blob.data, for: version)
        }
        return blob.data
    }

    static func isAppIconPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "repos" && parts[3] == "icon.png"
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
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
