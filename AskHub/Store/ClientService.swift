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
}

extension ClientService {
    func supports(_ intent: HumanIntent) -> Bool { true }
}

/// 書いた意図の控え
struct SendReceipt: Equatable {
    /// 依頼から作られる epic。司令塔が受け取る前から、この id で出す（依頼でなければ nil）
    var requestedEpicID: Epic.ID?
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

    var errorDescription: String? { message }
}
