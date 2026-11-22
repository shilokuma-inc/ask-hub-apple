import AskHubProtocol
import Foundation

/// 書いたら変わらないファイル（送った意図・司令塔の処理の記録）の、読んだ中身。
/// 30 秒ごとの取り直しのたびに読み直さないよう、一覧の sha が同じなら取り直さずに使う（変わらないファイルでも、sha が変われば読み直す）
final class ImmutableFileCache {
    private var envelopes: [String: (sha: String, envelope: IntentEnvelope)] = [:]
    private var records: [String: (sha: String, record: ConsumedIntentFile)] = [:]

    func envelope(at path: String, sha: String) -> IntentEnvelope? {
        envelopes[path].flatMap { $0.sha == sha ? $0.envelope : nil }
    }

    func consumed(at path: String, sha: String) -> ConsumedIntentFile? {
        records[path].flatMap { $0.sha == sha ? $0.record : nil }
    }

    func store(_ envelope: IntentEnvelope, at path: String, sha: String) {
        envelopes[path] = (sha, envelope)
    }

    func store(_ record: ConsumedIntentFile, at path: String, sha: String) {
        records[path] = (sha, record)
    }

    /// `paths` のほかを捨てる
    func keep(_ paths: Set<String>) {
        envelopes = envelopes.filter { paths.contains($0.key) }
        records = records.filter { paths.contains($0.key) }
    }
}
