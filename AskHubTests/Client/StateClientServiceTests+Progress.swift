@testable import AskHub
import AskHubClient
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 開始した後: 司令塔の受け取りを待つ間の出し方と、作業場所の用意・タスクごとの段階・子 PR・動いている Mac の出し方
extension StateClientServiceTests {
    private static let base = "repos/\(repo)/epics/\(epicID)"
    private static let branch = "askhub/\(epicID)"
    private static let head = "0123456789abcdef0123456789abcdef01234567"
    private static let prepareID = "01JCJ0B0000000000000000101"
    private static let implementFirstID = "01JCJ0B0000000000000000102"
    private static let reviewFirstID = "01JCJ0B0000000000000000103"
    private static let implementSecondID = "01JCJ0B0000000000000000104"
    private static let reviewSecondID = "01JCJ0B0000000000000000105"
    private static let fixSecondID = "01JCJ0B0000000000000000106"

    private static func goal(_ states: [String]) -> String {
        let titles = ["集計を作る", "一覧に出す", "通知する"]
        let tasks = zip(titles, states).enumerated().map { offset, pair in
            #"{"id":"t\#(offset + 1)","title":"\#(pair.0)","dependsOn":[],"state":"\#(pair.1)"}"#
        }
        return """
        {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
         "tasks":[\(tasks.joined(separator: ","))],"humanTasks":[]}
        """
    }

    private static func epic(stage: String, mac: String?, branch: String?) -> String {
        let mac = mac.map { #""\#($0)""# } ?? "null"
        let branch = branch.map { #""\#($0)""# } ?? "null"
        return """
        {"v":1,"id":"\(epicID)","repo":"\(repo)","title":"ランキング","summary":"ランキングの表示を変える","discussion":5,"stage":"\(stage)",
         "mac":\(mac),"branch":\(branch),"finalPullRequest":null,"goalVersion":1,"origin":null,
         "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2027-01-15T06:00:00Z"}
        """
    }

    private static func job(
        _ id: String,
        kind: String,
        task: String? = nil,
        state: String = "succeeded",
        attempts: Int = 1,
        dependsOn: [String] = [],
        input: String = "{}",
        nextRunAt: String? = nil,
        at time: String
    ) -> [String: String] {
        let task = task.map { #""\#($0)""# } ?? "null"
        let dependsOn = dependsOn.map { #""\#($0)""# }.joined(separator: ",")
        let nextRunAt = nextRunAt.map { #""\#($0)""# } ?? "null"
        return [
            "\(base)/jobs/\(id).json": """
            {"v":1,"id":"\(id)","kind":"\(kind)","repo":"\(repo)","epic":"\(epicID)","task":\(task),"assignedMac":"mac-mini",
             "needs":{"claude":true,"build":true},"dependsOn":[\(dependsOn)],"state":"\(state)","attempts":\(attempts),
             "nextRunAt":\(nextRunAt),"input":\(input),"origin":null,
             "createdAt":"2027-01-15T\(time):00Z","updatedAt":"2027-01-15T\(time):30Z"}
            """
        ]
    }

    private static func attempt(_ job: String, number: Int, outcome: String, heartbeatAt: String = "07:56") -> [String: String] {
        let ended = outcome == "running" ? "null" : #""2027-01-15T07:30:00Z""#
        let failure = outcome == "failed" ? #"{"class":"buildFailed","message":"ビルドが通らない"}"# : "null"
        return [
            "\(base)/attempts/\(job)/\(number).json": """
            {"v":1,"job":"\(job)","n":\(number),"mac":"mac-mini","startedAt":"2027-01-15T07:21:00Z",
             "heartbeatAt":"2027-01-15T\(heartbeatAt):00Z","endedAt":\(ended),"outcome":"\(outcome)","failure":\(failure)}
            """
        ]
    }

    private static func pullRequest(_ number: Int, reason: String? = nil) -> String {
        let reason = reason.map { #","reason":"\#($0)""# } ?? ""
        return #"{"pullRequest":\#(number),"head":"\#(head)"\#(reason)}"#
    }

    /// タスク 1 をマージし、タスク 2 の子 PR #42 をレビューしている epic（ジョブは司令塔のとおりに前のジョブへつなぐ）
    private static func runningEpic(extra: [String: String] = [:]) -> [String: String] {
        var files = askingEpic(stage: "running", extra: [
            "\(base)/epic.json": epic(stage: "running", mac: "mac-mini", branch: branch),
            "\(base)/goal.json": goal(["done", "running", "pending"])
        ])
        let jobs = [
            job(prepareID, kind: "prepareWorkspace", at: "06:00"),
            job(implementFirstID, kind: "implementTask", task: "t1", dependsOn: [prepareID], at: "06:01"),
            job(reviewFirstID, kind: "reviewTask", task: "t1", dependsOn: [implementFirstID], input: pullRequest(41), at: "06:30"),
            job(implementSecondID, kind: "implementTask", task: "t2", dependsOn: [reviewFirstID], at: "06:50"),
            job(
                reviewSecondID,
                kind: "reviewTask",
                task: "t2",
                state: "running",
                dependsOn: [implementSecondID],
                input: pullRequest(42),
                at: "07:20"
            ),
            attempt(reviewSecondID, number: 1, outcome: "running")
        ]
        for file in jobs + [extra] {
            files.merge(file) { _, new in new }
        }
        return files
    }

    private func store(_ text: String, at path: String, in store: InMemoryStateStore) async {
        await store.put(path, data: Data(text.utf8))
    }

    private static func date(_ time: String) -> Date {
        ISO8601DateFormatter().date(from: "2027-01-15T\(time):00Z") ?? .distantPast
    }

    /// 開始を送ると、司令塔が受け取るまで受け取り待ちを出す。受け付けたら、作業場所の用意を Mac が引き受けるのを待っていると出す
    @Test
    func startWaitsForCommanderThenShowsPreparation() async throws {
        let fixture = try makeService(files: Self.askingEpic(extra: [
            "\(Self.base)/epic.json": Self.epic(stage: "awaitingStart", mac: nil, branch: nil),
            "\(Self.base)/goal.json": Self.goal(["pending", "pending", "pending"])
        ]))
        let service = fixture.service
        _ = try await service.fetchSnapshot()
        let receipt = try await service.perform(.start(epicID: Self.epicID, macID: "mac-mini"))
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        #expect(receipt.intentID == envelope.nonce.rawValue)

        let waitingSnapshot = try await service.fetchSnapshot()
        #expect(waitingSnapshot.sentIntents.first { $0.id == receipt.intentID }?.state == .waiting)
        #expect(waitingSnapshot.sentIntents.first { $0.id == receipt.intentID }?.target == .goal(epicID: Self.epicID))
        let waiting = try #require(waitingSnapshot.epic(Self.epicID))
        #expect(waiting.stage == .implementing)
        #expect(waiting.workspace == .pending)
        #expect(waiting.activities.map(\.kind) == [.startRequested(macID: "mac-mini")])
        let line = EpicStatus.lines(for: waiting, in: waitingSnapshot, now: now).first
        #expect(line?.owner == .machine)
        #expect(line?.text == "mac-mini での開始を送りました。司令塔が受け取るのを待っています")

        // 司令塔は、作業場所の用意のジョブを作ってから epic を始め、処理した記録を残す
        let consumed = #"{"v":1,"kind":"startEpic","consumedAt":"2027-01-15T07:59:00Z","result":"accepted"}"#
        await store(consumed, at: StatePath.consumed(device: fixture.key.keyID, nonce: envelope.nonce), in: fixture.store)
        await store(Self.epic(stage: "running", mac: "mac-mini", branch: nil), at: "\(Self.base)/epic.json", in: fixture.store)
        for (path, text) in Self.job(Self.prepareID, kind: "prepareWorkspace", state: "assigned", attempts: 0, at: "07:59") {
            await store(text, at: path, in: fixture.store)
        }
        let acceptedSnapshot = try await service.fetchSnapshot()
        #expect(acceptedSnapshot.sentIntents.first { $0.id == receipt.intentID }?.state == .accepted(at: Self.date("07:59")))
        let accepted = try #require(acceptedSnapshot.epic(Self.epicID))
        #expect(accepted.workspace == .preparing)
        #expect(accepted.activities == [
            EpicActivity(
                kind: .step(.prepareWorkspace, .waitingForMac),
                since: Self.date("07:59").addingTimeInterval(30),
                worker: EpicActivity.Worker(macID: "mac-mini", heartbeatAt: nil)
            )
        ])
        #expect(accepted.history.contains { $0.text == "mac-mini で開始しました" })
        let acceptedLine = EpicStatus.lines(for: accepted, in: acceptedSnapshot, now: now).first?.text
        #expect(acceptedLine == "mac-mini が作業場所の用意を引き受けるのを待っています")
    }

    /// タスクごとの段階・子 PR・動いている Mac・最後に動いた時刻を出す
    @Test
    func runningEpicShowsStepsAndWorker() async throws {
        let snapshot = try await makeService(files: Self.runningEpic()).service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        #expect(epic.workspace == .ready(branch: Self.branch))
        #expect(epic.tasks.map(\.state) == [.done(pullRequest: 41), .inProgress(.reviewing(pullRequest: 42)), .pending])
        #expect(epic.tasks.map(\.pullRequest) == [41, 42, nil])
        #expect(epic.activities == [
            EpicActivity(
                kind: .step(.task("t2", .reviewing(pullRequest: 42)), .running(attempt: 1)),
                since: Self.date("07:21"),
                worker: EpicActivity.Worker(macID: "mac-mini", heartbeatAt: Self.date("07:56"))
            )
        ])
        let line = try #require(EpicStatus.lines(for: epic, in: snapshot, now: now).first)
        #expect(line.text == "mac-mini でタスク 2/3 の子 PR #42 のチェックを待って、レビューしています")
        #expect(line.detail?.hasPrefix("最後の動き ") == true)
        // 履歴は古い順（開始・作業ブランチ・マージ）
        let texts = epic.history.map(\.text)
        #expect(Array(texts.suffix(3)) == ["mac-mini で開始しました", "作業ブランチ \(Self.branch) を作りました", "タスク 1 をマージしました（#41）"])
        #expect(epic.history.map(\.date) == epic.history.map(\.date).sorted())
        // Mac の画面には、その Mac で動いているジョブを出す
        #expect(snapshot.mac("mac-mini")?.jobs.map(\.title) == ["ランキング: タスク 2「一覧に出す」の子 PR のレビュー"])
    }

    /// 直しは、何回目かと直す理由を出す。動いているジョブの試行は、最後の 1 つだけを読む
    @Test
    func fixingTaskShowsRoundAndReason() async throws {
        let reviewed = Self.job(Self.reviewSecondID, kind: "reviewTask", task: "t2", input: Self.pullRequest(42), at: "07:20")
        let files = Self.runningEpic(extra: reviewed
            .merging(Self.job(
                Self.fixSecondID,
                kind: "fixTask",
                task: "t2",
                state: "running",
                attempts: 2,
                dependsOn: [Self.reviewSecondID],
                input: Self.pullRequest(42, reason: "ci"),
                at: "07:40"
            )) { _, new in new }
            .merging(Self.attempt(Self.fixSecondID, number: 1, outcome: "failed")) { _, new in new }
            .merging(Self.attempt(Self.fixSecondID, number: 2, outcome: "running", heartbeatAt: "07:58")) { _, new in new })
        let fixture = try makeService(files: files)
        let snapshot = try await fixture.service.fetchSnapshot()
        let epic = try #require(snapshot.epic(Self.epicID))
        let fixing = EpicTask.Phase.fixing(pullRequest: 42, round: 1, reason: .checks)
        #expect(epic.tasks[1].state == .inProgress(fixing))
        #expect(epic.activities.map(\.kind) == [.step(.task("t2", fixing), .running(attempt: 2))])
        #expect(epic.activities.first?.worker?.heartbeatAt == Self.date("07:58"))
        let line = try #require(EpicStatus.lines(for: epic, in: snapshot, now: now).first)
        #expect(line.text == "mac-mini でタスク 2/3 の子 PR #42 の CI の失敗を直しています（1 回目）")
        #expect(line.detail?.hasSuffix(" · 試行 2") == true)

        let recording = RecordingStateStore(base: fixture.store)
        let documents = try await StateReader(store: recording, device: fixture.key.keyID).read()
        let attempts = documents.epics.first?.attempts ?? [:]
        #expect(attempts[ULID(rawValue: Self.fixSecondID)!]?.map(\.number) == [2])
        // 読みに行く試行も、動いているジョブの最後の 1 つだけ（前の試行と、終わったジョブの試行は要求しない）
        let attemptReads = await recording.reads.filter { $0.contains("/attempts/") }
        #expect(attemptReads == ["\(Self.base)/attempts/\(Self.fixSecondID)/2.json"])
    }

    /// 子 PR のレビューが人に渡されたら、止まったタスクにも子 PR の番号を残す
    @Test
    func blockedReviewKeepsPullRequest() async throws {
        let files = Self.runningEpic(extra: Self.job(
            Self.reviewSecondID,
            kind: "reviewTask",
            task: "t2",
            state: "waitingHuman",
            dependsOn: [Self.implementSecondID],
            input: Self.pullRequest(42),
            at: "07:20"
        ))
        let epic = try #require(try await makeService(files: files).service.fetchSnapshot().epic(Self.epicID))
        #expect(epic.tasks[1].state == .failed(pullRequest: 42))
        #expect(epic.tasks[1].pullRequest == 42)
        #expect(epic.blocker?.title == "タスク 2「一覧に出す」の子 PR のレビューが止まっています")
    }

    /// 人に渡されたタスクのジョブは、タスクを止まっていると出し、「対処が要ります」にタスクの名前で出す
    @Test
    func waitingTaskJobIsShownAsBlocker() async throws {
        var files = Self.runningEpic()
        files.removeValue(forKey: "\(Self.base)/jobs/\(Self.reviewSecondID).json")
        let waiting = Self.job(
            Self.implementSecondID,
            kind: "implementTask",
            task: "t2",
            state: "waitingHuman",
            dependsOn: [Self.reviewFirstID],
            at: "06:50"
        )
        files.merge(waiting) { _, new in new }
        files.merge(Self.attempt(Self.implementSecondID, number: 1, outcome: "failed")) { _, new in new }
        let epic = try #require(try await makeService(files: files).service.fetchSnapshot().epic(Self.epicID))
        #expect(epic.tasks[1].state == .failed(pullRequest: nil))
        #expect(epic.activities.isEmpty)
        #expect(epic.blocker?.title == "タスク 2「一覧に出す」の実装が止まっています")
        #expect(epic.blocker?.summary == "ビルドが通らない")
        #expect(epic.blocker?.actions == [.retry])

        // やり直しを送ったら、司令塔が受け取るまでは止まったとは出さず、受け取り待ちを「いま」に出す
        let fixture = try makeService(files: files)
        let blocked = try #require(try await fixture.service.fetchSnapshot().epic(Self.epicID)?.blocker)
        try await fixture.service.perform(.resolveBlocker(epicID: Self.epicID, action: .retry, instruction: "", target: blocked.target))
        let snapshot = try await fixture.service.fetchSnapshot()
        let retrying = try #require(snapshot.epic(Self.epicID))
        #expect(retrying.blocker == nil)
        #expect(retrying.tasks[1].state == .inProgress(.implementing))
        #expect(retrying.activities.map(\.kind) == [.step(.task("t2", .implementing), .retryRequested)])
        let line = EpicStatus.lines(for: retrying, in: snapshot, now: now).first?.text
        #expect(line == "タスク 2/3「一覧に出す」の実装のやり直しを送りました。司令塔が受け取るのを待っています")
    }

    /// Mac が引き受ける前のジョブは引き受けを待っていると出し、試し直しの時刻を待つジョブはその時刻を出す
    @Test
    func queuedTaskJobShowsWaiting() async throws {
        var files = Self.runningEpic()
        files.removeValue(forKey: "\(Self.base)/jobs/\(Self.reviewSecondID).json")
        let queuedJob = Self.job(Self.implementSecondID, kind: "implementTask", task: "t2", state: "assigned", attempts: 0, at: "07:50")
        files.merge(queuedJob) { _, new in new }
        let fixture = try makeService(files: files)
        let queued = try #require(try await fixture.service.fetchSnapshot().epic(Self.epicID))
        #expect(queued.tasks[1].state == .inProgress(.implementing))
        #expect(queued.activities.map(\.kind) == [.step(.task("t2", .implementing), .waitingForMac)])

        let retry = Self.job(
            Self.implementSecondID,
            kind: "implementTask",
            task: "t2",
            state: "assigned",
            nextRunAt: "2027-01-15T09:00:00Z",
            at: "07:50"
        )
        for (path, text) in retry {
            await store(text, at: path, in: fixture.store)
        }
        let retrying = try #require(try await fixture.service.fetchSnapshot().epic(Self.epicID))
        #expect(retrying.activities.map(\.kind) == [.step(.task("t2", .implementing), .retrying(at: Self.date("09:00")))])
    }

    /// タスクがすべて終わったら、最終 PR の段取りを待っていると出す
    @Test
    func finishedTasksAreShown() async throws {
        let reviewed = Self.job(Self.reviewSecondID, kind: "reviewTask", task: "t2", input: Self.pullRequest(42), at: "07:20")
        var files = Self.runningEpic(extra: reviewed)
        files["\(Self.base)/goal.json"] = Self.goal(["done", "done", "done"])
        let epic = try #require(try await makeService(files: files).service.fetchSnapshot().epic(Self.epicID))
        #expect(epic.tasks.map(\.state) == [.done(pullRequest: 41), .done(pullRequest: 42), .done(pullRequest: nil)])
        #expect(epic.activities.map(\.kind) == [.tasksFinished])
    }
}

/// 読んだパスを覚える状態リポジトリ（読む回数を確かめる）
private actor RecordingStateStore: StateStore {
    let base: InMemoryStateStore
    private(set) var reads: [String] = []

    init(base: InMemoryStateStore) {
        self.base = base
    }

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        reads.append(path)
        return try await base.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await base.list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        try await base.write(path, data: data, replacing: sha, message: message)
    }
}
