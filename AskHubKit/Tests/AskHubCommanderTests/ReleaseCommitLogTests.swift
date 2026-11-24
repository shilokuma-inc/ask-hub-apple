@testable import AskHubCommander
import AskHubProtocol
import AskHubPullRequests
import Foundation
import Testing

/// 同じ時刻に違うコミットの Upload が流れたとき、job のログのビルドの番号で配信したコミットを決める
extension ReleaseWatchTests {
    static let datedBuild = "20261123.114349"
    static let developNext = String(repeating: "d", count: 40)

    func overlappingUploadRun(_ number: Int, sha: String, startedMinutesAgo: Double) -> ActionsRun {
        ActionsRun(
            id: 19_000_000_000 + number,
            runNumber: number,
            path: ReleaseCommitFinder.uploadWorkflow,
            headSHA: sha,
            event: "push",
            startedAt: Self.now.addingTimeInterval(-startedMinutesAgo * 60),
            updatedAt: Self.now.addingTimeInterval(-(startedMinutesAgo - 40) * 60)
        )
    }

    /// prime-pick の 1.4.0: develop（39）と release（40）が同じコミットで同時に流れ、上げる前に develop の次のコミット（41）も流れた。
    /// 上げたのは 40 だけで、ビルドの番号は UTC の日時（実行番号ではない）
    func overlappingUploads() -> [ActionsRun] {
        [
            overlappingUploadRun(39, sha: Self.released, startedMinutesAgo: 630),
            overlappingUploadRun(40, sha: Self.released, startedMinutesAgo: 629),
            overlappingUploadRun(41, sha: Self.developNext, startedMinutesAgo: 605)
        ]
    }

    @Test func narrowsOverlappingUploadsByBuildNumberInJobLogs() async throws {
        try await addRepository()
        live(build: Self.datedBuild)
        let runs = overlappingUploads()
        hosting.state.withLock { state in
            state.runs = runs
            state.jobs = [
                runs[0].id: [ActionsJob(id: 391, name: "upload", conclusion: "success")],
                runs[1].id: [
                    ActionsJob(id: 401, name: "build", conclusion: "skipped"),
                    ActionsJob(id: 402, name: "upload", conclusion: "success")
                ],
                runs[2].id: [ActionsJob(id: 411, name: "upload", conclusion: "success")]
            ]
            state.logs = [
                391: "2026-11-23T11:43:30.0000000Z   CURRENT_PROJECT_VERSION=20261123.114323\n",
                402: "2026-11-23T11:43:55.0000000Z Build settings from command line:\n"
                    + "2026-11-23T11:43:55.0000000Z     CURRENT_PROJECT_VERSION = 20261123.114349\n",
                411: "2026-11-23T11:55:50.0000000Z   CURRENT_PROJECT_VERSION=20261123.115545\n"
            ]
        }
        await watch().refresh()

        let file = try await release()
        #expect(file.commit == .init(
            sha: Self.released, source: .uploadRun, platform: .iOS, build: Self.datedBuild, run: runs[1].id, runNumber: 40
        ))
        #expect(file.tag?.created == true && file.problem == nil)
        // 飛ばした job のログは読まない
        #expect(hosting.state.withLock { $0.logReads } == [391, 402, 411])
    }

    @Test func leavesOverlappingUploadsToHumanWhenLogsDoNotShowTheBuild() async throws {
        try await addRepository()
        live(build: Self.datedBuild)
        let runs = overlappingUploads()
        hosting.state.withLock { state in
            state.runs = runs
            state.jobs = Dictionary(uniqueKeysWithValues: runs.map { run in
                (run.id, [ActionsJob(id: run.runNumber, name: "upload", conclusion: "success")])
            })
            // 39 は違う番号、40 のログは保存の期限を過ぎて消え、41 のログにはビルドの番号が出ていない
            state.logs = [39: "CURRENT_PROJECT_VERSION=20261123.114323\n", 41: "** EXPORT SUCCEEDED **\n"]
        }
        await watch().refresh()

        let file = try await release()
        #expect(file.commit == nil)
        #expect(file.problem?.step == .commit && file.problem?.needsHuman == true)
        #expect(file.problem?.message == "ビルド (\(Self.datedBuild)) を上げた Upload の実行を 1 つに決められない（候補: 実行 39（aaaaaaa）・"
            + "実行 40（aaaaaaa）・実行 41（ddddddd）。job のログのビルドの番号でも絞れない）。タグ v1.1.0 を手で付けると、そのコミットで続ける")
        #expect(hosting.state.withLock { $0.logReads } == [39, 40, 41])
    }

    @Test func readsNoLogsWhenTimeDecidesOrCandidatesAreTooMany() async throws {
        try await addRepository()
        live(build: Self.datedBuild)
        // 同じコミットの候補だけなら、ログを読まずに決める
        let same = Array(overlappingUploads().prefix(2))
        hosting.state.withLock { $0.runs = same }
        await watch().refresh()
        #expect(try await release().commit?.sha == Self.released)
        #expect(hosting.state.withLock { ($0.jobReads, $0.logReads) } == ([], []))

        // 候補が多すぎれば、読まずに人に回す
        var file = try await release()
        file.commit = nil
        file.tag = nil
        file.notes = nil
        try await put(file)
        let many = (0...ReleaseCommitFinder.maximumRunsToRead).map { index in
            overlappingUploadRun(50 + index, sha: index == 0 ? Self.released : Self.developNext, startedMinutesAgo: 630 - Double(index))
        }
        hosting.state.withLock { state in
            state.runs = many
            state.tags = [:]
        }
        clock.advance(minutes: 10)
        await watch().refresh()
        let left = try await release()
        #expect(left.commit == nil && left.problem?.message.contains("候補が多いので job のログは読まない") == true)
        #expect(hosting.state.withLock { ($0.jobReads, $0.logReads) } == ([], []))
    }
}
