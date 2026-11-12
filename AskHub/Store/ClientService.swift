import Foundation

/// クライアントの読み書きの窓口。
///
/// デモのデータ（`DemoClientService`）と、状態リポジトリ（`StateClientService`。AskHubKit のプロトコルの型を画面用のモデルに
/// 変換し、人の意図を署名して書く）の 2 つがある
protocol ClientService: AnyObject {
    /// 取り直しの間隔
    var refreshInterval: Duration { get }
    /// 状態の全体を読む。一部の取得元だけ読めないときは、`ClientSnapshot.sourceFailures` に入れて返す
    func fetchSnapshot() async throws -> ClientSnapshot
    /// 人の意図を書く。控えは、依頼の後に送った依頼へ移るときだけ使う
    @discardableResult
    func perform(_ intent: HumanIntent) async throws -> SendReceipt
    /// その意図を送れるか。送れない操作のボタンは画面に出さない（状態リポジトリでは、段階 3 の操作をまだ送れない）
    func supports(_ intent: HumanIntent) -> Bool
    /// 同じ意図（同じ対象と版・同じ中身）を最後に送った記録。分からなければ nil
    func lastSend(of intent: HumanIntent) -> SentRecord?
    /// 判断のカードのスクショ（状態リポジトリの中のパス）の中身。読めなければ投げる
    func screenshot(at path: String) async throws -> Data
    /// 対象のアプリのアイコン（`RepositoryIcon.stored`）の中身。読めなければ投げる
    func appIcon(at path: String, version: String) async throws -> Data
    /// 最後に読んだ状態に、送り終えていない意図（取り消しの猶予の間を含む。古い順）を送った結果として当てたもの。
    /// 押した直後から済んだ形で出すのに使う（送り終えて読み直していない意図も当てる）。当てられない（まだ読めていない）ときは nil
    func snapshot(overlaying intents: [HumanIntent]) -> ClientSnapshot?
    /// 受け付けの記録だけを軽く確かめる間隔。司令塔の受け取りを待つ意図がある間だけ確かめる。確かめられない窓口は nil
    var receiptCheckInterval: Duration? { get }
    /// 送った意図（`SendReceipt.Sent.id`）を司令塔が処理したか（受け付けた・断った）を、処理の記録だけを読んで確かめる。状態は読まない
    func hasReceipt(for intentID: String) async throws -> Bool
    /// マージ中の epic があるときに、マージ済みになるまで読み直す間隔（ふだんの取り直しより短い）。読み直さない窓口は nil
    var mergeWatchInterval: Duration? { get }
}

extension ClientService {
    func supports(_ intent: HumanIntent) -> Bool { true }

    func snapshot(overlaying intents: [HumanIntent]) -> ClientSnapshot? { nil }

    var receiptCheckInterval: Duration? { nil }

    func hasReceipt(for intentID: String) async throws -> Bool { false }

    var mergeWatchInterval: Duration? { nil }

    func screenshot(at path: String) async throws -> Data {
        throw ClientServiceError(message: "このデータの元にはスクショが無い")
    }

    func appIcon(at path: String, version: String) async throws -> Data {
        throw ClientServiceError(message: "このデータの元にはアプリのアイコンが無い")
    }
}

/// 書いた意図の控え（失敗の `ClientServiceError` が持つので、nonisolated にする）
nonisolated struct SendReceipt: Equatable {
    /// 書いた 1 つの意図
    nonisolated struct Sent: Equatable {
        /// `ClientSnapshot.sentIntents` の id。司令塔が受け付けたかを読み直しで確かめるのに使う
        var id: String
        /// その意図が働きかける対象（まとめて OK なら、その意図で答えたカード）。分からなければ nil（操作の対象すべてとみなす）
        var target: IntentTarget?
    }

    /// 依頼から作られる epic。司令塔が受け取る前から、この id で出す（依頼でなければ nil）
    var requestedEpicID: Epic.ID?
    /// 書いた意図（送った順）。まとめて OK のように 1 つの操作が複数の意図になるときは、そのすべて。分からなければ空
    var sent: [Sent] = []

    init(requestedEpicID: Epic.ID? = nil, sent: [Sent] = []) {
        self.requestedEpicID = requestedEpicID
        self.sent = sent
    }

    init(requestedEpicID: Epic.ID? = nil, intentIDs: [String]) {
        self.init(requestedEpicID: requestedEpicID, sent: intentIDs.map { Sent(id: $0, target: nil) })
    }

    init(requestedEpicID: Epic.ID? = nil, intentID: String?) {
        self.init(requestedEpicID: requestedEpicID, intentIDs: [intentID].compactMap(\.self))
    }

    /// 書いた意図の id（送った順）
    var intentIDs: [String] {
        sent.map(\.id)
    }

    /// 最後に送った意図の id
    var intentID: String? {
        intentIDs.last
    }
}

/// 前に送った同じ意図
struct SentRecord: Equatable {
    var sentAt: Date
    /// 司令塔がまだ受け取っていない
    var isWaiting: Bool
}

/// 読み書きの失敗。画面には `message` だけを出す（トークンなどの値は入れない）
struct ClientServiceError: LocalizedError, Equatable {
    var message: String
    /// 複数の意図になる操作の途中で失敗したときの、失敗する前に書けた意図（書けた分は司令塔が受け取る）
    var sentBeforeFailure: SendReceipt?
    /// GitHub の上限に当たったときの、次に試せるまでの目安（上限でなければ nil）
    var retryAfter: Duration?

    var errorDescription: String? { message }
}
