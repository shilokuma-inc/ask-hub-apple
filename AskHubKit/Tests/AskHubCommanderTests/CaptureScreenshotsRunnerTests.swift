import AskHubBuild
@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 判断のカードのスクショを撮る（Before は base との分岐点、After は作業ブランチの先頭。状態リポジトリと GitHub に上げ、最終 PR の本文を書き直す）
struct CaptureScreenshotsRunnerTests {
    typealias Fixture = FinalJobFixture
    static let base = String(repeating: "b", count: 40)

    /// 作業ブランチの先頭（head）と base との分岐点（base）の写しに、撮れる画面の一覧を置いた epic
    struct Given {
        let fixture = Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Capture-\(UUID().uuidString)")
        var head: URL { root.appendingPathComponent("head") }
        var base: URL { root.appendingPathComponent("base") }

        func prepare(
            headScenes: [String],
            baseScenes: [String]?,
            decisions: [DecisionsFile.Item],
            screens: [DecisionsFile.ScreenChange]? = nil
        ) async throws {
            for (directory, scenes) in [(head, headScenes), (base, baseScenes)] {
                try FileManager.default.createDirectory(at: directory.appendingPathComponent("App"), withIntermediateDirectories: true)
                guard let scenes else { continue }
                let file = ScreenshotScenesFile(scenes: scenes.map { .init(id: $0, title: "\($0) の画面", arguments: ["-demoOpen", $0]) })
                try JSONEncoder().encode(file).write(to: directory.appendingPathComponent("App/scenes.json"))
            }
            fixture.git.update { [head, base] state in
                state.epicDirectory = head
                state.commitDirectory = base
                state.mergeBaseCommit = CaptureScreenshotsRunnerTests.base
            }
            fixture.pulls.update { $0.pulls[512] = Fixture.openPull() }
            try await fixture.prepare(decisions: DecisionsFile(items: decisions, screens: screens))
        }

        func run() async throws -> JobResult {
            var settings = try Fixture.settings()
            let phone = BuildDestination.simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro"))
            settings.screenshots = ScreenshotSettings(scenes: "App/scenes.json", destination: phone)
            let input = PullRequestInput(pullRequest: 512, head: Fixture.head).jobInput
            let job = fixture.job(.captureScreenshots, "01", input: input)
            return try await CaptureScreenshotsRunner(environment: try fixture.environment(settings: settings)).execute(job)
        }

        func path(_ commit: String, _ scene: String) -> String {
            StatePath.screenshot(Fixture.Tasks.repo, Fixture.Tasks.epic, commit: commit, scene: scene)
        }

        func stored(_ path: String) async -> String? {
            await fixture.tasks.store.data(at: path).flatMap { String(bytes: $0, encoding: .utf8) }
        }
    }

    static func decision(_ id: String, scene: String?) -> DecisionsFile.Item {
        DecisionsFile.Item(id: id, task: "t1", pullRequest: 41, visible: true, what: "見出し \(id)", why: "ゴールの t1", scene: scene)
    }

    @Test func shootsBeforeAndAfterAndRewritesPullRequestBody() async throws {
        let given = Given()
        defer { try? FileManager.default.removeItem(at: given.root) }
        // d1・d2 は同じ画面、d3 は epic で足した画面（base の一覧に無い）、d4 は撮る画面を選んでいない
        try await given.prepare(
            headScenes: ["ranking", "ranking-empty"],
            baseScenes: ["ranking"],
            decisions: [
                Self.decision("d1", scene: "ranking"),
                Self.decision("d2", scene: "ranking"),
                Self.decision("d3", scene: "ranking-empty"),
                Self.decision("d4", scene: nil)
            ]
        )
        let result = try await given.run()
        #expect(result.failure == nil)
        #expect(result.outputs?.commit == Fixture.head)
        let shots = try #require(result.outputs?.screenshots)
        #expect(shots.keys.sorted() == ["d1", "d2", "d3"])
        // 同じコミット・画面の画像は 1 つだけ置き、いくつかの仮決めが同じものを指す
        let d1 = try #require(shots["d1"])
        #expect(d1.before == given.path(Self.base, "ranking"))
        #expect(d1.after == given.path(Fixture.head, "ranking"))
        #expect(d1.head == Fixture.head)
        #expect(d1.note == nil)
        #expect(shots["d2"]?.after == d1.after)
        #expect(await given.stored(given.path(Self.base, "ranking")) == "base/ranking")
        #expect(await given.stored(given.path(Fixture.head, "ranking-empty")) == "head/ranking-empty")
        // epic で足した画面は Before なし
        #expect(shots["d3"]?.before == nil)
        #expect(shots["d3"]?.note == "Before なし（この画面は epic で足した）")
        // base と head をそれぞれ 1 回ずつビルドして撮る。DerivedData は分ける
        let captures = given.fixture.builds.current.captures
        #expect(captures.map(\.sourceDirectory) == [given.head, given.base])
        #expect(captures.map { $0.scenes.map(\.id) } == [["ranking", "ranking-empty"], ["ranking"]])
        #expect(captures.map(\.derivedData.lastPathComponent) == ["DerivedData", "DerivedData-base"])
        #expect(captures[0].scenes[0].arguments == ["-demoOpen", "ranking"])
        // GitHub には画像ごとに 1 回だけ上げ、本文の表に載せる
        #expect(given.fixture.pulls.current.uploads.count == 3)
        #expect(d1.beforeURL != nil && d1.afterURL != nil && shots["d2"]?.afterURL == d1.afterURL)
        let body = try #require(given.fixture.pulls.current.bodies.last)
        #expect(body.number == 512)
        #expect(body.body.contains(#"<img src="\#(try #require(d1.afterURL))" alt="d1 After" width="300">"#))
        #expect(body.body.contains("### d4: 見出し d4\n\n- なぜ: ゴールの t1\n- ほかの案: なし\n- 画面の変化: \(FinalPullRequestBody.noScene)"))
        #expect(given.fixture.git.current.calls.contains("release 01JCJ0C0000000000000000001"))
    }

    @Test func reusesShotsOfSameCommitAndKeepsGoingWhenUploadFails() async throws {
        let given = Given()
        defer { try? FileManager.default.removeItem(at: given.root) }
        try await given.prepare(headScenes: ["ranking"], baseScenes: ["ranking"], decisions: [Self.decision("d1", scene: "ranking")])
        // Before は前に撮った（base が同じ）。After だけ撮る
        await given.fixture.tasks.store.put(given.path(Self.base, "ranking"), data: Data("前に撮った".utf8))
        given.fixture.pulls.update { $0.uploadError = .notFound }
        let result = try await given.run()
        let d1 = try #require(result.outputs?.screenshots?["d1"])
        #expect(d1.before == given.path(Self.base, "ranking"))
        #expect(given.fixture.builds.current.captures.map(\.sourceDirectory) == [given.head])
        #expect(!given.fixture.git.current.calls.contains { $0.hasPrefix("checkOutCommit") })
        // GitHub に上げられなくても止めない（AskHub のクライアントで見られる）
        #expect(d1.beforeURL == nil)
        #expect(d1.note == "GitHub に上げられなかった（書き込みの権限が無い）。AskHub のクライアントで見られる")
        #expect(given.fixture.pulls.current.bodies.last?.body.contains(FinalPullRequestBody.onlyInClient) == true)
    }

    @Test func writesReasonWhenBuildFailsOrSceneListIsMissing() async throws {
        let given = Given()
        defer { try? FileManager.default.removeItem(at: given.root) }
        try await given.prepare(headScenes: ["ranking"], baseScenes: nil, decisions: [Self.decision("d1", scene: "ranking")])
        given.fixture.builds.update { [head = given.head] in $0.captureProblems[head] = "アプリのビルドが通らない（終了コード 65）" }
        let result = try await given.run()
        #expect(result.failure == nil)
        let d1 = try #require(result.outputs?.screenshots?["d1"])
        #expect(d1.before == nil && d1.after == nil)
        #expect(d1.note == "After を撮れなかった（アプリのビルドが通らない（終了コード 65））・Before なし（撮れる画面の一覧（App/scenes.json）が無い）")
    }

    @Test func shootsScreenChangesAndAddsThemToPullRequestBody() async throws {
        let given = Given()
        defer { try? FileManager.default.removeItem(at: given.root) }
        try await given.prepare(
            headScenes: ["ranking", "ranking-empty"],
            baseScenes: ["ranking"],
            decisions: [],
            screens: [.init(scene: "ranking"), .init(scene: "ranking-empty")]
        )
        let result = try await given.run()
        let changes = try #require(result.outputs?.screenChanges)
        #expect(changes.map(\.scene) == ["ranking", "ranking-empty"])
        #expect(changes.map(\.title) == ["ranking の画面", "ranking-empty の画面"])
        #expect(changes[0].screenshots?.before == given.path(Self.base, "ranking"))
        #expect(changes[0].screenshots?.afterURL != nil)
        #expect(changes[1].screenshots?.note == "Before なし（この画面は epic で足した）")
        #expect(result.outputs?.screenshots == nil)
        let body = try #require(given.fixture.pulls.current.bodies.last?.body)
        // 見出しの下に空行を重ねず、すぐに表を置く
        #expect(body.contains("## 画面の変化\n\n### ranking の画面（`ranking`）\n\n| Before | After |"))
        #expect(body.contains(#"alt="ranking After" width="300">"#))
        #expect(body.contains("見える仮決めはありません。"))
    }

    @Test func decisionSharingScreenChangePointsToItInsteadOfRepeatingTable() async throws {
        let given = Given()
        defer { try? FileManager.default.removeItem(at: given.root) }
        // d1 は画面の変化と同じ画面、d2 は画面の変化に無い画面
        try await given.prepare(
            headScenes: ["ranking", "ranking-empty"],
            baseScenes: ["ranking", "ranking-empty"],
            decisions: [Self.decision("d1", scene: "ranking"), Self.decision("d2", scene: "ranking-empty")],
            screens: [.init(scene: "ranking")]
        )
        let result = try await given.run()
        // スクショは今どおり仮決めにも書く（AskHub のカードに出す）
        #expect(result.outputs?.screenshots?["d1"]?.after == given.path(Fixture.head, "ranking"))
        let body = try #require(given.fixture.pulls.current.bodies.last?.body)
        #expect(body.contains("- 画面の変化: 下の「画面の変化」の `ranking` を見る"))
        #expect(!body.contains(#"alt="d1 After""#))
        #expect(body.components(separatedBy: #"alt="ranking After""#).count == 2)
        // 画面の変化に無い画面のカードには、今どおり表を載せる
        #expect(body.contains(#"alt="d2 After" width="300">"#))
    }

    @Test func doesNothingWithoutChosenScenes() async throws {
        let given = Given()
        defer { try? FileManager.default.removeItem(at: given.root) }
        try await given.prepare(headScenes: ["ranking"], baseScenes: ["ranking"], decisions: [Self.decision("d1", scene: nil)])
        let result = try await given.run()
        #expect(result.outputs?.screenshots == nil)
        #expect(given.fixture.builds.current.captures.isEmpty)
        #expect(given.fixture.pulls.current.bodies.isEmpty)
    }

    @Test func implementationRulesAskToKeepSceneListOnlyWhenConfigured() {
        let rules = TaskRules.systemPrompt(repository: Fixture.Tasks.repo, facts: "", roundTrips: 5, screenshotScenes: "App/scenes.json")
        #expect(rules.contains("撮れる画面の一覧（App/scenes.json）に足すか直します"))
        #expect(rules.contains("デモのデータだけを使います"))
        let plain = TaskRules.systemPrompt(repository: Fixture.Tasks.repo, facts: "", roundTrips: 5)
        #expect(!plain.contains("撮れる画面の一覧"))
    }
}
