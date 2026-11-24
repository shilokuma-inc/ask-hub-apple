@testable import AskHub
import Foundation
import Testing

/// 実機確認の残り: 配信した版の確認を畳む規則、あなたの番の 1 行、まとめて判断するから外すこと、デモのまとめての答え
@MainActor
struct VerificationBacklogTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var snapshot: ClientSnapshot { DemoScenario.standard.snapshot(now: now) }
    private static let repo = "demo-studio/habit-ios"

    private func date(hours: Double) -> Date {
        now.addingTimeInterval(hours * 60 * 60)
    }

    private func release(_ version: String, repo: String = repo, detectedHours: Double, uploadedHours: [Double?] = []) -> Release {
        Release(
            repositoryID: repo,
            version: version,
            platforms: uploadedHours.enumerated().map { offset, hours in
                Release.Platform(name: offset == 0 ? "iOS" : "macOS", build: "\(offset + 1)", uploadedAt: hours.map(date(hours:)))
            },
            detectedAt: date(hours: detectedHours),
            updatedAt: date(hours: detectedHours)
        )
    }

    private func submission(_ version: String, branchHours: Double?, hotfixFrom: String? = nil) -> Submission {
        var submission = Submission(
            repositoryID: Self.repo, version: version, startedInAskHub: true, revision: 1, createdAt: now, updatedAt: now
        )
        submission.branchCreatedAt = branchHours.map(date(hours:))
        submission.hotfixFrom = hotfixFrom
        return submission
    }

    // MARK: 畳む規則

    /// 版を切った時刻は、release ブランチを作った時刻、分からなければビルドを上げた最も早い時刻、それも無ければ配信を見つけた時刻
    @Test
    func cutTimePrefersBranchThenUploadThenDetection() {
        let distributed = release("1.3.0", detectedHours: -1, uploadedHours: [-20, -30, nil])
        #expect(VerificationFold.cutAt(of: distributed, submissions: [submission("1.3.0", branchHours: -50)]) == date(hours: -50))
        // 記録があってもブランチの時刻が無い・ほかの版の記録は使わない
        let others = [submission("1.3.0", branchHours: nil), submission("1.2.0", branchHours: -90)]
        #expect(VerificationFold.cutAt(of: distributed, submissions: others) == date(hours: -30))
        #expect(VerificationFold.cutAt(of: release("1.3.0", detectedHours: -1, uploadedHours: [nil]), submissions: []) == date(hours: -1))
    }

    /// epic が入った版（マージした時刻と同じか後に最初に切った版）の、次の版を配信したら畳む。ほかのリポジトリの版では畳まない
    @Test
    func foldsWhenNextReleaseAfterTheEpicsReleaseShips() {
        let releases = [
            release("1.4.0", detectedHours: -1, uploadedHours: [-5]),
            release("1.3.0", detectedHours: -20, uploadedHours: [-30]),
            release("1.2.0", detectedHours: -60, uploadedHours: [-80]),
            release("9.0.0", repo: "demo-studio/rain-ios", detectedHours: -1, uploadedHours: [-2])
        ]
        func folding(mergedHours: Double?) -> String? {
            VerificationFold.foldingRelease(
                mergedAt: mergedHours.map(date(hours:)), repositoryID: Self.repo, releases: releases, submissions: []
            )?.version
        }
        // 1.2.0 に入った epic は 1.3.0 で、1.3.0 に入った epic は 1.4.0 で畳む
        #expect(folding(mergedHours: -90) == "1.3.0")
        #expect(folding(mergedHours: -40) == "1.4.0")
        #expect(folding(mergedHours: -30) == "1.4.0")
        // 1.4.0 に入った epic は、次の版が出るまで畳まない。マージした後に切った版が無い・マージした時刻が分からないときも畳まない
        #expect(folding(mergedHours: -10) == nil)
        #expect(folding(mergedHours: -3) == nil)
        #expect(folding(mergedHours: nil) == nil)
        // 配信を見つけたのがマージの後でも、ブランチをマージの前に作った版には入っていない
        let branched = VerificationFold.foldingRelease(
            mergedAt: date(hours: -10),
            repositoryID: Self.repo,
            releases: [release("1.4.0", detectedHours: -1, uploadedHours: [-5]), release("1.5.0", detectedHours: 0, uploadedHours: [-1])],
            submissions: [submission("1.4.0", branchHours: -12)]
        )
        #expect(branched == nil)
    }

    /// hotfix の版はタグから切るので develop の epic を含まない。epic が入った版にも、次の版にも数えない
    @Test
    func hotfixReleasesAreNotCounted() {
        let releases = [
            release("1.4.0", detectedHours: -1, uploadedHours: [-5]),
            release("1.3.1", detectedHours: -15, uploadedHours: [-20]),
            release("1.3.0", detectedHours: -25, uploadedHours: [-30])
        ]
        let hotfix = [submission("1.3.1", branchHours: -20, hotfixFrom: "1.3.0")]
        // 1.3.0 の後にマージした epic は 1.4.0 に入る（1.3.1 には入らない）ので、まだ畳まない
        let afterCut = VerificationFold.foldingRelease(
            mergedAt: date(hours: -25), repositoryID: Self.repo, releases: releases, submissions: hotfix
        )
        #expect(afterCut == nil)
        // 1.3.0 に入った epic は、hotfix の 1.3.1 ではなく 1.4.0 で畳む
        let beforeCut = VerificationFold.foldingRelease(
            mergedAt: date(hours: -40), repositoryID: Self.repo, releases: releases, submissions: hotfix
        )
        #expect(beforeCut?.version == "1.4.0")
    }

    /// デモでは、献立メモの 2.0.0（材料の epic が入った版）の次の 2.0.1 を配信したので材料の epic を畳み、雨雲チェックと習慣ログの epic は確かめるものに残す（新しくマージした順）
    @Test
    func demoBacklogSplitsOpenAndFolded() {
        let backlog = VerificationBacklog(snapshot: snapshot)
        #expect(backlog.open.map(\.id) == ["rain-widget", "habit-review"])
        #expect(backlog.openItemCount == 5)
        #expect(backlog.folded.map(\.id) == ["recipe-cart"])
        #expect(backlog.folded.first?.foldedBy?.version == "2.0.1")
    }

    // MARK: あなたの番

    /// 実機確認は epic をまたいで「時間のあるときに」の 1 行にまとめ、実機確認の一覧を開く。畳んだものは数えずに添える
    @Test
    func inboxShowsOneVerificationRow() throws {
        let rows = InboxBuilder.items(from: snapshot, now: now).filter { $0.kind == .verification }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.urgency == .whenFree)
        #expect(row.title == "実機で確かめる")
        #expect(row.detail == "2 件の epic · 5 項目\nほかに配信した版の確認 1 件")
        #expect(row.context == "雨雲チェック・習慣ログ")
        #expect(row.route == .verifications)
        // アイコンは最も新しくマージした epic のアプリ
        #expect(row.repositoryID == DemoData.repositoryID("rain-ios"))
        #expect(row.targets.contains(.verifications(epicID: "habit-review")))
        #expect(!row.targets.contains(.verifications(epicID: "recipe-cart")))
    }

    /// 畳んだ確認だけが残ったら、あなたの番には出さない
    @Test
    func inboxHidesRowWhenOnlyFoldedRemain() {
        var snapshot = snapshot
        for id in ["rain-widget", "habit-review"] {
            snapshot.updateEpic(id) { epic in
                let items = epic.finalReview?.verifications ?? []
                epic.finalReview?.verifications = items.map { item in
                    var item = item
                    item.state = .confirmed
                    return item
                }
            }
        }
        #expect(!InboxBuilder.items(from: snapshot, now: now).contains { $0.kind == .verification })
        #expect(VerificationBacklog(snapshot: snapshot).folded.count == 1)
    }

    // MARK: デモ

    /// まとめて確認した・確かめずに閉じたは、その epic のまだ答えていない項目すべてに付く。答えた項目は変えない
    @Test
    func demoServiceClosesRemainingItems() async throws {
        let service = DemoClientService(scenario: .standard, reactionDelay: 10, refreshInterval: .seconds(1)) { [now] in now }
        try await service.perform(.verify(epicID: "rain-widget", itemID: "v1", reply: .problem(note: "時刻が出ない")))
        try await service.perform(.closeVerifications(epicID: "rain-widget", reply: .skipped(note: "次の版で見る")))
        #expect(service.state.epic("rain-widget")?.finalReview?.verifications.map(\.state) == [
            .problem(note: "時刻が出ない"), .skipped(note: "次の版で見る"), .skipped(note: "次の版で見る")
        ])
        try await service.perform(.closeVerifications(epicID: "habit-review", reply: .confirmed))
        #expect(service.state.epic("habit-review")?.finalReview?.verifications.allSatisfy { $0.state == .confirmed } == true)
        #expect(VerificationBacklog(snapshot: service.state).open.isEmpty)
    }
}
