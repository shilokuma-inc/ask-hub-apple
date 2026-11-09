@testable import AskHub
import AskHubProtocol
import Foundation
import Testing

/// 最終 PR の判断のカードのスクショ（ワーカーが撮って状態リポジトリに置いたもの）
extension StateClientServiceTests {
    /// 撮影の設定があるリポジトリの最終 PR: 撮ったスクショは状態リポジトリのパスで持ち、撮れなかったわけ・撮る前・画面が無いことを出し分ける
    @Test
    func decisionCardsShowStoredScreenshotsAndReasons() async throws {
        let shots = "\(Self.finalBase)/screenshots"
        let before = "\(shots)/\(String(repeating: "b", count: 40))-ranking.png"
        let after = "\(shots)/\(Self.finalHead)-ranking.png"
        let decisions = """
        {"v":1,"screens":[{"scene":"ranking","title":"ランキングの一覧","screenshots":{"after":"\(after)","note":"Before なし（この画面は epic で足した）"}},
                          {"scene":"ranking-empty"}],
         "items":[
          {"id":"d1","task":"t2","pullRequest":41,"visible":true,"what":"見出しを短くした","why":"iPhone の幅に収める","alternatives":[],
           "scene":"ranking","screenshots":{"before":"\(before)","after":"\(after)","head":"\(Self.finalHead)","note":null}},
          {"id":"d2","task":"t2","pullRequest":41,"visible":true,"what":"空のときの案内","why":"初回に迷わない","alternatives":[],
           "scene":"ranking-empty","screenshots":{"after":"\(after)","note":"Before なし（この画面は epic で足した）"}},
          {"id":"d3","task":"t2","pullRequest":41,"visible":true,"what":"順位を太字にした","why":"一目で分かる","alternatives":[],"scene":"ranking"},
          {"id":"d4","task":"t1","visible":true,"what":"並べ替えを止める","why":"検索中に崩れない","alternatives":[]}
        ]}
        """
        var files = Self.reviewingEpic()
        files["\(Self.finalBase)/decisions.json"] = decisions
        files["repos/\(Self.repo)/repo.json"] = """
        {"v":1,"repo":"\(Self.repo)","platform":"apple","maxConcurrentEpics":1,"appKit":null,"protection":{"appliedAt":null},
         "addedAt":"2026-11-01T00:00:00Z","build":{"xcode":{"project":"App.xcodeproj","scheme":"App",
         "destinations":[{"platform":"iOS","deviceType":"iPhone 17 Pro"}]},"childChecks":["build"],"finalChecks":["build"],
         "screenshots":{"scenes":".askhub/screenshot-scenes.json","destination":{"platform":"iOS","deviceType":"iPhone 17 Pro"}}}}
        """
        files[after] = "After の画像"
        let fixture = try makeService(files: files)
        let snapshot = try await fixture.service.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        let cards = try #require(snapshot.epic(Self.epicID)?.finalReview?.decisions)
        #expect(cards.map(\.before) == [.stored(before), nil, nil, nil])
        #expect(cards.map(\.after) == [.stored(after), .stored(after), nil, nil])
        #expect(cards.map(\.screenshotNote) == [
            nil,
            "Before なし（この画面は epic で足した）",
            "スクショを撮っています",
            "スクショ無し（この仮決めが出る画面は、撮れる画面の一覧に無い）"
        ])
        // 画面の変化（仮決めに結びつかない画面）も、撮ったものと撮る前を出し分ける
        let changes = try #require(snapshot.epic(Self.epicID)?.finalReview?.screenChanges)
        #expect(changes.map(\.id) == ["ranking", "ranking-empty"])
        #expect(changes.map(\.title) == ["ランキングの一覧", "ranking-empty"])
        #expect(changes.map(\.after) == [.stored(after), nil])
        #expect(changes.map(\.note) == ["Before なし（この画面は epic で足した）", "スクショを撮っています"])
        // 画像は状態リポジトリから読む（epic の screenshots/ の下の PNG だけ）
        #expect(try await fixture.service.screenshot(at: after) == Data("After の画像".utf8))
        await #expect(throws: ClientServiceError.self) { try await fixture.service.screenshot(at: before) }
        await #expect(throws: ClientServiceError.self) { try await fixture.service.screenshot(at: "keys/1.json") }
    }

    /// 撮影の設定を後で外した（・repo.json を読めない）ときも、撮ったスクショがあれば「設定が無い」とは出さない
    @Test
    func storedScreenshotsKeepTheirNoteWithoutSetting() {
        let shots = DecisionsFile.Screenshots(after: "\(Self.finalBase)/screenshots/\(Self.finalHead)-ranking.png", note: "Before なし")
        let item = DecisionsFile.Item(id: "d1", task: "t1", visible: true, what: "見出し", why: "幅", scene: "ranking", screenshots: shots)
        #expect(StateSnapshotBuilder.screenshotNote(of: item, capturesScreenshots: false) == "Before なし")
        var plain = item
        plain.screenshots = nil
        #expect(StateSnapshotBuilder.screenshotNote(of: plain, capturesScreenshots: false) == StateSnapshotBuilder.noScreenshotSetting)
    }
}
