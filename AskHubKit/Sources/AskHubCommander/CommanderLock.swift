import Foundation

/// 司令塔の中で、人の意図の処理と、Claude のジョブの結果を書く処理を 1 つずつ行う。
///
/// Claude の呼び出し（数分かかる）は外で並んで行い、状態を読み直してから書き終えるまでだけをこの中で行う。
/// 結果を書く途中で人が答え直す（回答の受け付けが割り込む）と、古い結果で先に進めてしまうため。中から入り直さない（入れ子にしない）
public actor CommanderLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// 入るのを待っている数（テストで、待ちに入ったことを確かめる）
    var waitingCount: Int { waiters.count }
    /// 中に入っているものがあるか（テストで、待つ間は排他の外にいることを確かめる）
    var isHeld: Bool { locked }

    nonisolated public func withLock<T: Sendable>(_ body: () async throws(CommanderError) -> T) async throws(CommanderError) -> T {
        await acquire()
        do {
            let value = try await body()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard locked else {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            // 次に待っているものに、そのまま渡す
            waiters.removeFirst().resume()
        }
    }
}
