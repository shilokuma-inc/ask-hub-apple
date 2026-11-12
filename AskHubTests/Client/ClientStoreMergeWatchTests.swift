@testable import AskHub
import Foundation
import Testing

/// マージ中の epic を、マージ済みになるまで短い間隔で読み直すこと
@MainActor
struct ClientStoreMergeWatchTests {
    /// 読んだ回数を数え、返す状態を差し替えられる窓口
    private final class CountingService: ClientService {
        let refreshInterval: Duration = .seconds(60)
        var mergeWatchInterval: Duration? = .milliseconds(20)
        var snapshot: ClientSnapshot
        private(set) var fetchCount = 0

        init(snapshot: ClientSnapshot) {
            self.snapshot = snapshot
        }

        func fetchSnapshot() async throws -> ClientSnapshot {
            fetchCount += 1
            return snapshot
        }

        func perform(_ intent: HumanIntent) async throws -> SendReceipt {
            SendReceipt()
        }

        func lastSend(of intent: HumanIntent) -> SentRecord? {
            nil
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 最終 PR のある epic の状態を `state` にした状態
    private func snapshot(_ state: FinalReview.State) throws -> (snapshot: ClientSnapshot, epicID: Epic.ID) {
        var snapshot = DemoScenario.standard.snapshot(now: now)
        let index = try #require(snapshot.epics.firstIndex { $0.finalReview != nil })
        snapshot.epics[index].finalReview?.state = state
        return (snapshot, snapshot.epics[index].id)
    }

    /// `condition` が成り立つまで待つ（2 秒まで）
    private func wait(until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// マージ中の間は、ふだんの取り直しを待たずに短い間隔で読み直し、マージ済みになったらやめる
    @Test
    func rereadsMergingEpicUntilMerged() async throws {
        let (merging, epicID) = try snapshot(.merging)
        let service = CountingService(snapshot: merging)
        let store = ClientStore(service: service, now: { [now] in now })
        await store.refresh()
        #expect(store.epic(epicID)?.finalReview?.state == .merging)

        await wait { service.fetchCount >= 3 }
        #expect(service.fetchCount >= 3)

        let merged = FinalReview.State.merged(at: now, automatic: false)
        service.snapshot = try snapshot(merged).snapshot
        await wait { store.epic(epicID)?.finalReview?.state == merged }
        #expect(store.epic(epicID)?.finalReview?.state == merged)
        // マージ済みになったら、短い間隔の読み直しをやめる
        await wait { store.mergeWatch.task == nil }
        let count = service.fetchCount
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.fetchCount == count)
    }

    /// マージ中の epic が無ければ、短い間隔では読まない
    @Test
    func doesNotRereadWithoutMergingEpic() async throws {
        let service = CountingService(snapshot: try snapshot(.reviewable).snapshot)
        let store = ClientStore(service: service, now: { [now] in now })
        await store.refresh()
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.fetchCount == 1)
        #expect(store.mergeWatch.task == nil)
    }

    /// マージ中になってから決めた長さを過ぎた epic は、ふだんの取り直しに任せる
    @Test
    func stopsAfterWindow() {
        var watch = MergeWatch()
        let merging = DemoScenario.standard.snapshot(now: now)
        var snapshot = merging
        guard let index = snapshot.epics.firstIndex(where: { $0.finalReview != nil }) else {
            Issue.record("最終 PR のある epic がデモに無い")
            return
        }
        snapshot.epics[index].finalReview?.state = .merging
        // mutating の呼び出しは #expect のマクロの中に書けないので、外で求める
        let started = watch.update(with: snapshot, now: now, window: 60)
        let within = watch.update(with: snapshot, now: now.addingTimeInterval(59), window: 60)
        let expired = watch.update(with: snapshot, now: now.addingTimeInterval(60), window: 60)
        #expect(started)
        #expect(within)
        #expect(!expired)
        // マージ中でなくなれば忘れ、またマージ中になったら、そこから数え直す
        let finished = watch.update(with: merging, now: now.addingTimeInterval(61), window: 60)
        #expect(!finished)
        #expect(watch.mergingSince.isEmpty)
        let restarted = watch.update(with: snapshot, now: now.addingTimeInterval(62), window: 60)
        #expect(restarted)
    }
}
