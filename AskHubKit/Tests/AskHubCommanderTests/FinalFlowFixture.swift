@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 最終 PR の段取りのテストで使う状態（タスクがすべて済んだ epic・成功した作業場所の用意・Mac の生きている印・人の意図）
struct FinalFlowFixture {
    static let repo = EpicHandlersTests.repo
    static let commander = EpicHandlersTests.commander
    static let laptop = EpicHandlersTests.laptop
    static let now = EpicHandlersTests.now
    static let epicID = ULID(rawValue: "01JCEP1C000000000000000002")!
    static let origin = TaskFlowTests.origin
    static let pullRequest = 512

    let store = InMemoryStateStore()
    let key = P256.Signing.PrivateKey()
    var keyID: KeyID { IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation) }
    var context: CommanderContext { CommanderContext(store: store, mac: Self.commander) { Self.now } }
    var flow: TaskFlow { TaskFlow(context: context) }

    static func sha(_ character: Character) -> String {
        String(repeating: character, count: 40)
    }

    /// 仕分ける前の仮決め
    static func decision(_ id: String, task: String = "t1") -> DecisionsFile.Item {
        DecisionsFile.Item(id: id, task: task, pullRequest: 41, what: "見出し \(id) を短くした", why: "iPhone の幅に収める", alternatives: ["2 行にする"])
    }

    // MARK: - 読み書き

    func put<File: StateFile>(_ file: File, at path: String) async throws {
        await store.put(path, data: try StateFileCoder.encode(file))
    }

    func read<File: StateFile>(_ type: File.Type, at path: String) async throws -> File? {
        try await store.data(at: path).map { try StateFileCoder.decode(File.self, from: $0) }
    }

    func jobs() async throws -> [JobFile] {
        var jobs: [JobFile] = []
        for entry in try await store.list(StatePath.jobs(Self.repo, epic: Self.epicID)) ?? [] {
            jobs.append(try StateFileCoder.decode(JobFile.self, from: #require(await store.data(at: entry.path))))
        }
        return jobs
    }

    func job(_ id: ULID) async throws -> JobFile {
        try #require(try await read(JobFile.self, at: StatePath.job(Self.repo, epic: Self.epicID, job: id)))
    }

    func epic() async throws -> EpicFile {
        try #require(try await read(EpicFile.self, at: StatePath.epic(Self.repo, Self.epicID)))
    }

    func decisions() async throws -> DecisionsFile {
        try #require(try await read(DecisionsFile.self, at: StatePath.decisions(Self.repo, Self.epicID)))
    }

    /// 今の状態で 1 回進める（司令塔の 1 周で、ジョブの状態を決めた後にすること）
    func advance() async throws -> TaskFlow.Advanced {
        await flow.advance(epics: [try await epic()], jobs: try await jobs())
    }

    // MARK: - 状態を作る

    /// タスクがすべて済んだ実装中の epic（ゴールの t1・t2 が done）と、成功した作業場所の用意と、仮決め。
    /// epic の Mac の生きている印は `macSeen` 秒前（nil なら書かない）
    func finished(decisions: [DecisionsFile.Item] = [], macSeen: TimeInterval? = 0) async throws {
        let time = Timestamp(Self.now)
        let epic = EpicFile(
            id: Self.epicID,
            repo: Self.repo,
            title: "ランキング",
            stage: .running,
            mac: Self.laptop,
            branch: "askhub/\(Self.epicID)",
            goalVersion: 1,
            createdAt: time,
            updatedAt: time
        )
        try await put(epic, at: StatePath.epic(Self.repo, Self.epicID))
        let tasks: [GoalFile.Task] = [.init(id: "t1", title: "集計を作る", state: .done), .init(id: "t2", title: "画面を作る", state: .done)]
        try await put(GoalFile(version: 1, summary: "ランキングを作る", doneWhen: ["…"], tasks: tasks), at: StatePath.goal(Self.repo, Self.epicID))
        let spec = JobSpec(kind: .prepareWorkspace, mac: Self.laptop, needs: .init(claude: false, build: false))
        let prepare = context.job(spec, for: epic, origin: Self.origin, seed: "")
        try await put(prepare, at: StatePath.job(Self.repo, epic: Self.epicID, job: prepare.id))
        try await succeed(prepare, outputs: .init(commit: Self.sha("0"), branch: "askhub/\(Self.epicID)"))
        if !decisions.isEmpty { try await put(DecisionsFile(items: decisions), at: StatePath.decisions(Self.repo, Self.epicID)) }
        if let macSeen { try await putMac(Self.laptop, seen: macSeen) }
    }

    /// 撮影の設定（`build.screenshots`）のある repo.json
    func putScreenshotSetting() async throws {
        let phone = BuildDestination.simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro"))
        let build = RepositoryFile.Build(
            xcode: try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [phone]),
            childChecks: ["build"],
            finalChecks: ["build"],
            screenshots: ScreenshotSettings(scenes: "App/screenshot-scenes.json", destination: phone)
        )
        let repository = RepositoryFile(repo: Self.repo, platform: .apple, build: build, addedAt: Timestamp(Self.now))
        try await put(repository, at: StatePath.repository(Self.repo))
    }

    /// Mac の生きている印（`seen` 秒前）
    func putMac(_ name: MacName, seen: TimeInterval) async throws {
        let check = SelfCheck(checkedAt: Timestamp(Self.now), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        let mac = MacFile(
            mac: name,
            kind: .resident,
            seenAt: Timestamp(Self.now.addingTimeInterval(-seen)),
            versions: .init(worker: "1.0"),
            diskFreeGB: 200,
            load: 0.2,
            capacity: .init(claude: 1, build: 1),
            selfCheck: check
        )
        try await put(mac, at: StatePath.mac(name))
    }

    /// ジョブを成功にし、成功した試行を書く（司令塔が試行を読んでジョブの状態を決めた後）
    @discardableResult
    func succeed(_ job: JobFile, outputs: AttemptFile.Outputs = .init()) async throws -> JobFile {
        var job = job
        job.attempts += 1
        job.state = .succeeded
        let time = Timestamp(Self.now)
        let attempt = AttemptFile(
            job: job.id,
            number: job.attempts,
            mac: job.assignedMac ?? Self.commander,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            outputs: outputs
        )
        try await put(attempt, at: StatePath.attempt(Self.repo, epic: Self.epicID, job: job.id, number: job.attempts))
        try await put(job, at: StatePath.job(Self.repo, epic: Self.epicID, job: job.id))
        return job
    }

    /// 進めて、作ったジョブ（1 つ）を返す
    func next(_ kind: JobKind, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JobFile {
        let created = try await advance().created
        #expect(created.map(\.kind) == [kind], sourceLocation: sourceLocation)
        return try #require(created.first, sourceLocation: sourceLocation)
    }

    /// 検証・仕分け（`visible` を見えるとする）・最終 PR の作成を済ませ、head `a` の最終 PR のレビューを作るところまで進める
    func openedFinalPullRequest(visible: [String]? = nil) async throws -> JobFile {
        let verify = try await next(.verifyBeforeFinal)
        try await succeed(verify)
        if let visible {
            let classify = try await next(.classifyDecisions)
            try await succeed(classify, outputs: .init(visibleDecisions: visible))
        }
        let open = try await next(.openFinalPullRequest)
        try await succeed(open, outputs: .init(pullRequest: Self.pullRequest, commit: Self.sha("a")))
        return try await next(.reviewFinalPullRequest)
    }

    /// 仮決め `d1`（見える）と `d2`（内部の細部）があり、head `a` の最終 PR のレビューが通って、人の確認を待っている epic。最後のレビューを返す
    func reviewing() async throws -> JobFile {
        try await finished(decisions: [Self.decision("d1"), Self.decision("d2")])
        let review = try await openedFinalPullRequest(visible: ["d1"])
        let succeeded = try await succeed(review, outputs: .init(commit: Self.sha("a"), verdict: .ready, mergeRisks: []))
        #expect(try await advance().created.isEmpty)
        #expect(try await epic().stage == .reviewing)
        return succeeded
    }

    // MARK: - 人の意図

    func intake() -> IntentIntake {
        IntentIntake(
            context: context,
            verifier: IntentVerifier(publicKeys: [keyID: key.publicKey.derRepresentation]),
            handlers: ["decision": DecisionHandler(), "approveMerge": ApproveMergeHandler(), "instructFinal": InstructFinalHandler()]
        )
    }

    /// 署名した人の意図を `intents/` に置き、その参照を返す。番号は置いた順に大きくする（司令塔は番号の順に処理する）
    @discardableResult
    func place(
        _ kind: String,
        target: IntentEnvelope.Target,
        head: String,
        payload: [String: JSONValue] = [:]
    ) async throws -> IntentReference {
        let placed = try await store.list("\(StatePath.intents)/\(keyID)")?.count ?? 0
        let envelope = IntentEnvelope(
            kind: kind,
            repo: Self.repo,
            target: target,
            targetVersion: head,
            payload: payload,
            issuedAt: Timestamp(Self.now),
            nonce: .generate(at: Self.now.addingTimeInterval(Double(placed))),
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await store.put(StatePath.intent(device: keyID, nonce: envelope.nonce), data: CanonicalJSON.data(for: stored))
        return IntentReference(keyId: keyID, nonce: envelope.nonce)
    }

    /// 判断のカードへの答えを置く
    @discardableResult
    func answer(_ id: String, _ choice: DecisionsFile.Choice, note: String = "", head: String = sha("a")) async throws -> IntentReference {
        var payload: [String: JSONValue] = ["answer": .string(choice.rawValue)]
        if !note.isEmpty { payload["note"] = .string(note) }
        return try await place("decision", target: .init(type: "decision", epic: Self.epicID, id: id), head: head, payload: payload)
    }

    /// マージの承認を置く
    @discardableResult
    func approve(head: String = sha("a")) async throws -> IntentReference {
        try await place("approveMerge", target: .init(type: "finalPullRequest", epic: Self.epicID), head: head)
    }

    /// 最終 PR への指示を置く
    @discardableResult
    func instruct(_ instruction: String, head: String = sha("a")) async throws -> IntentReference {
        let target = IntentEnvelope.Target(type: "finalPullRequest", epic: Self.epicID)
        return try await place("instructFinal", target: target, head: head, payload: ["instruction": .string(instruction)])
    }
}
