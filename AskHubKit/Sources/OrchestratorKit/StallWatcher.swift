import Foundation

/// 異常終了したループを再開するか（副作用なし）。
///
/// 起動してもすぐ落ちるループ（起動スクリプトの失敗・設定の不備）を延々と起動し直さないよう、
/// epic が進まないまま止まった回数を数え、`maxAttempts` 回を超えたら再開をやめる。
/// goal / state が変われば（ループが進めば）数え直す
public struct StallWatcher: Sendable {
    public enum Action: Sendable, Equatable {
        /// 再開する。`attempt` は epic が進まないまま再開した回数（1 から）
        case resume(attempt: Int)
        /// 進まないまま `attempts` 回再開したので、やめる（epic が変わるまで再開しない）
        case giveUp(attempts: Int)
    }

    struct Entry: Sendable, Equatable {
        /// 最後に再開したときの epic。これと同じなら、ループは進んでいない
        var snapshot: EpicSnapshot
        var attempts: Int
        var gaveUp: Bool
    }

    /// epic が進まないまま再開する回数の上限
    public static let maxAttempts = 3

    /// キーは担当リポジトリの `fullName` を小文字にしたもの
    private(set) var entries: [String: Entry] = [:]

    public init() {}

    public mutating func update(repositoryKey key: String, status: LoopStatus, snapshot: EpicSnapshot) -> Action? {
        guard status.stalled, !status.processAlive, snapshot.branch?.hasPrefix("epic/") == true else {
            return nil
        }
        var entry = entries[key] ?? Entry(snapshot: snapshot, attempts: 0, gaveUp: false)
        if entry.snapshot != snapshot {
            entry = Entry(snapshot: snapshot, attempts: 0, gaveUp: false)
        }
        guard !entry.gaveUp else {
            return nil
        }
        if entry.attempts >= Self.maxAttempts {
            entry.gaveUp = true
            entries[key] = entry
            return .giveUp(attempts: entry.attempts)
        }
        entry.attempts += 1
        entries[key] = entry
        return .resume(attempt: entry.attempts)
    }
}
