import Foundation

/// クライアントの読み書きの窓口。
///
/// 今はデモのデータ（`DemoClientService`）だけ。バックエンド（プロトコル・状態リポジトリ）ができたら、
/// AskHubKit の型を画面用のモデルに変換し、人の意図を署名して書く実装を足す
protocol ClientService: AnyObject {
    /// 取り直しの間隔
    var refreshInterval: Duration { get }
    /// 状態の全体を読む。一部の取得元だけ読めないときは、`ClientSnapshot.sourceFailures` に入れて返す
    func fetchSnapshot() async throws -> ClientSnapshot
    /// 人の意図を書く
    func perform(_ intent: HumanIntent) async throws
}

/// 読み書きの失敗。画面には `message` だけを出す（トークンなどの値は入れない）
struct ClientServiceError: LocalizedError, Equatable {
    var message: String

    var errorDescription: String? { message }
}
