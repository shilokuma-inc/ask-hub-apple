@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

// MARK: - 手動ループの最終 PR への指示

extension LoopStatusModelTests {
    struct CheckFailed: Error {}

    /// 渡された手動ループを記録し、決めた結果を返す（失敗もさせられる）
    final class RecordingFinalInstructions: ManualLoopFinalInstructionsChecking {
        private let result: Result<Set<String>, CheckFailed>
        private let recorded = OSAllocatedUnfairLock<[[ManualLoopTarget]]>(initialState: [])

        init(_ result: Result<Set<String>, CheckFailed> = .success([])) {
            self.result = result
        }

        var calls: [[ManualLoopTarget]] {
            recorded.withLock { $0 }
        }

        func loopsWithUnprocessedInstructions(_ loops: [ManualLoopTarget]) async throws -> Set<String> {
            recorded.withLock { $0.append(loops) }
            return try result.get()
        }
    }

    /// 信用する author が作った手動ループの Discussion（担当のコメントなし）
    private static func manualLoop(_ repository: String, number: Int) -> ManualLoopRecord {
        ManualLoopRecord(
            subject: InboxSubject(
                kind: .discussion,
                nodeID: "\(repository)#\(number)",
                repository: repository,
                number: number,
                title: "ゴール",
                url: URL(string: "https://github.com/\(repository)/discussions/\(number)")!,
                author: TrustedAuthors.defaultLogins[0]
            ),
            comments: []
        )
    }

    @Test func sampleAsksAssigneeToResumeForFinalPullRequestInstruction() async {
        let model = LoopStatusModel.sample()
        await model.refresh()
        let items = model.manualLoopItems(now: Date())
        #expect(items.filter(\.finalInstructionsPending).map(\.epic.subject.shortReference) == ["zankyo-apple#8"])
    }

    @Test func checksFinalPullRequestInstructionsOfManualLoops() async {
        let manual = SectionsSource(waiting: [], usageLimited: [], manualLoops: [Self.manualLoop("o/r", number: 12)])
        let checker = RecordingFinalInstructions(.success(["o/r#12"]))
        let model = Self.model(sections: manual, finalInstructions: checker)
        await model.refresh()

        // 手動ループの状態がまだ無ければ、epic は分からない（最終 PR は本文のゴール元の Discussion の目印で探す）
        #expect(checker.calls == [[ManualLoopTarget(repository: "o/r", discussion: 12, epic: nil)]])
        #expect(model.manualLoopItems(now: Date()).map(\.finalInstructionsPending) == [true])
    }

    @Test func toleratesFinalPullRequestInstructionsFailure() async {
        let manual = SectionsSource(waiting: [], usageLimited: [], manualLoops: [Self.manualLoop("o/r", number: 12)])
        let checker = RecordingFinalInstructions(.failure(CheckFailed()))
        let model = Self.model(sections: manual, finalInstructions: checker)
        await model.refresh()

        #expect(model.state == .loaded)
        #expect(model.manualLoopItems(now: Date()).map(\.finalInstructionsPending) == [false])
    }

    @Test func doesNotCheckFinalPullRequestsWithoutManualLoops() async {
        let checker = RecordingFinalInstructions(.success(["o/r#12"]))
        let model = Self.model(sections: SectionsSource(waiting: [], usageLimited: []), finalInstructions: checker)
        await model.refresh()
        #expect(checker.calls.isEmpty)
    }
}
