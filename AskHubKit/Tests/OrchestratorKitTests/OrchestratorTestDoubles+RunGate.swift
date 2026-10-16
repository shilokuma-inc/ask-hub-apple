import Foundation
import os
import Testing

/// テストが決めた時まで処理を返さないようにする。`FakeRuntime.run` が、裏の処理の途中で止まったままになるようにして確かめるのに使う
final class RunGate: Sendable {
    private struct State {
        var holds = false
        var held: [CheckedContinuation<Void, Never>] = []

        mutating func takeHeld() -> [CheckedContinuation<Void, Never>] {
            defer { held = [] }
            return held
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 待たせているあいだは、`release` か `setHolds(false)` が呼ばれるまで戻らない
    func pass() async {
        guard state.withLock({ $0.holds }) else {
            return
        }
        await withCheckedContinuation { continuation in
            // 確かめてから入れるまでの間に `setHolds(false)` されたら、待たずに戻る
            let resumesNow = state.withLock { state in
                guard state.holds else {
                    return true
                }
                state.held.append(continuation)
                return false
            }
            if resumesNow {
                continuation.resume()
            }
        }
    }

    /// `true` にすると、以後の `pass` を待たせる。`false` にすると、待っているものも返す
    func setHolds(_ holds: Bool) {
        let released = state.withLock { state in
            state.holds = holds
            return holds ? [] : state.takeHeld()
        }
        released.forEach { $0.resume() }
    }

    /// 待たせているものをすべて返す（以後の `pass` は、`setHolds(false)` にするまで待たせる）
    func release() {
        state.withLock { $0.takeHeld() }.forEach { $0.resume() }
    }

    /// 待たせているものが `count` 件になるまで待つ（裏の処理が `pass` に入るのを待つ）。数秒で諦める
    func waitForHeld(_ count: Int) async {
        var waited = 0
        while state.withLock({ $0.held.count }) < count, waited < 5_000 {
            try? await Task.sleep(for: .milliseconds(1))
            waited += 1
        }
        let held = state.withLock { $0.held.count }
        if held < count {
            Issue.record("待たせている処理が \(count) 件になりませんでした（\(held) 件）")
        }
    }
}

// `run` を待たせる。裏で実行するコマンド（最終 PR のコンフリクトの解消など）の途中を確かめる
extension FakeRuntime {
    /// `true` にすると、以後の `run` はテストが `releaseHeldRuns` を呼ぶまで返さない。`false` にすると、待っているものも返す
    func setHoldsRuns(_ holds: Bool) {
        runGate.setHolds(holds)
    }

    /// 待たせている `run` をすべて返す（以後の `run` は、`setHoldsRuns(false)` にするまで待たせる）
    func releaseHeldRuns() {
        runGate.release()
    }

    /// 待たせている `run` が `count` 件になるまで待つ（裏の処理が `run` に入るのを待つ）
    func waitForHeldRuns(_ count: Int) async {
        await runGate.waitForHeld(count)
    }
}
