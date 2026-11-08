@testable import AskHub
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 状態リポジトリの読み込み: 並べて読んでも結果と失敗の順が変わらないこと、同時の要求の上限、送った意図を読み直さないこと
@MainActor
struct StateReaderTests {
    static let alpha = "example/alpha"
    static let beta = "example/beta"
    static let running = "01JCEP1C0000000000000000E1"
    static let asking = "01JCEP1C0000000000000000E2"
    static let merged = "01JCEP1C0000000000000000E3"
    static let other = "01JCEP1C0000000000000000E4"
    static let broken = #"{"v":1}"#

    /// 読むたびに、パスで決まる長さだけ待つ（後に頼んだものが先に返る）。頼んだ順と、同時に動いた数の最大を覚える
    actor ShuffledStore: StateStore {
        let base: InMemoryStateStore
        let delays: Bool
        private(set) var reads: [String] = []
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0

        init(_ base: InMemoryStateStore, delays: Bool = true) {
            self.base = base
            self.delays = delays
        }

        func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
            reads.append(path)
            await wait(path)
            return try await base.read(path)
        }

        func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
            await wait(directory)
            return try await base.list(directory)
        }

        func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
            try await base.write(path, data: data, replacing: sha, message: message)
        }

        private func wait(_ path: String) async {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            if delays {
                // 長いパスほど早く返す（epic・ジョブの中のファイルが、一覧より先に返る）
                let milliseconds = max(1, 40 - path.utf8.count % 37)
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
            inFlight -= 1
        }

        func readCount(of path: String) -> Int {
            reads.filter { $0 == path }.count
        }
    }

    static func epic(_ id: String, repo: String, stage: String) -> String {
        """
        {"v":1,"id":"\(id)","repo":"\(repo)","title":"\(id)","summary":"並べて読む","discussion":5,"stage":"\(stage)",
         "mac":null,"branch":null,"finalPullRequest":null,"goalVersion":null,"origin":null,
         "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-01T01:00:00Z"}
        """
    }

    static func job(_ id: String, repo: String, epic: String, state: String = "succeeded", attempts: Int = 1) -> String {
        """
        {"v":1,"id":"\(id)","kind":"implementTask","repo":"\(repo)","epic":"\(epic)","task":"t1","assignedMac":"mac-mini",
         "needs":{"claude":true,"build":true},"dependsOn":[],"state":"\(state)","attempts":\(attempts),
         "nextRunAt":null,"input":{},"origin":null,"createdAt":"2027-01-15T06:00:00Z","updatedAt":"2027-01-15T06:00:30Z"}
        """
    }

    static func attempt(_ job: String, number: Int) -> String {
        """
        {"v":1,"job":"\(job)","n":\(number),"mac":"mac-mini","startedAt":"2027-01-15T07:21:00Z",
         "heartbeatAt":"2027-01-15T07:56:00Z","endedAt":null,"outcome":"running","failure":null}
        """
    }

    static func mac(_ name: String) -> String {
        """
        {"v":1,"mac":"\(name)","kind":"alwaysOn","seenAt":"2027-01-15T07:50:00Z","versions":{"worker":"1.0.0","xcode":"27.1"},
         "diskFreeGB":120,"load":3.2,"capacity":{"claude":2,"build":1},
         "selfCheck":{"checkedAt":"2027-01-15T07:50:00Z","keychain":"ok","githubToken":"ok","claudeToken":"ok"}}
        """
    }

    static func jobID(_ suffix: String) -> String { "01JCJ0B0000000000000000\(suffix)" }

    /// 2 つのリポジトリ・4 つの epic と、読めないファイル（形の違うジョブ・置き場所の違うジョブ・試行・質問・Mac・司令塔・送った意図）
    static func files(device: KeyID) -> [String: String] {
        let first = "repos/\(alpha)/epics/\(running)"
        let second = "repos/\(alpha)/epics/\(asking)"
        let third = "repos/\(alpha)/epics/\(merged)"
        let fourth = "repos/\(beta)/epics/\(other)"
        return [
            "repos/\(alpha)/repo.json": """
            {"v":1,"repo":"\(alpha)","platform":"apple","maxConcurrentEpics":1,"appKit":null,
             "protection":{"appliedAt":null},"addedAt":"2026-11-01T00:00:00Z"}
            """,
            "\(first)/epic.json": epic(running, repo: alpha, stage: "running"),
            "\(first)/jobs/\(jobID("JA1")).json": job(jobID("JA1"), repo: alpha, epic: running, state: "waitingHuman", attempts: 2),
            "\(first)/attempts/\(jobID("JA1"))/1.json": broken,
            "\(first)/attempts/\(jobID("JA1"))/2.json": attempt(jobID("JA1"), number: 2),
            "\(first)/jobs/\(jobID("JA2")).json": broken,
            "\(first)/jobs/\(jobID("JA3")).json": job(jobID("JA3"), repo: beta, epic: other),
            "\(first)/jobs/\(jobID("JA4")).json": job(jobID("JA4"), repo: alpha, epic: running, state: "running", attempts: 1),
            "\(first)/attempts/\(jobID("JA4"))/1.json": attempt(jobID("JA4"), number: 1),
            "\(second)/epic.json": epic(asking, repo: alpha, stage: "asking"),
            "\(second)/questions.json": broken,
            "\(third)/epic.json": epic(merged, repo: alpha, stage: "merged"),
            "\(third)/jobs/\(jobID("JA5")).json": job(jobID("JA5"), repo: alpha, epic: merged),
            "\(fourth)/epic.json": epic(other, repo: beta, stage: "running"),
            "\(fourth)/jobs/\(jobID("JB1")).json": job(jobID("JB1"), repo: beta, epic: other),
            "macs/mac-a.json": mac("mac-a"),
            "macs/mac-b.json": broken,
            "commander.json": broken,
            "intents/\(device.rawValue)/01JCJ0C0000000000000000001.json": "{}"
        ]
    }

    static func key() throws -> DeviceSigningKey {
        try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
    }

    /// 比べやすい形（順番つき）
    static func summary(_ documents: StateDocuments) -> [String] {
        documents.repositories.map { "repo \($0.repo.rawValue)" }
            + documents.epics.flatMap { epic in
                ["epic \(epic.epic.id.rawValue) questions=\(epic.questions != nil)"]
                    + epic.jobs.map { "job \($0.id.rawValue)" }
                    + epic.attempts.keys.sorted { $0.rawValue < $1.rawValue }.map { id in
                        "attempts \(id.rawValue) \(epic.attempts[id]?.map(\.number) ?? [])"
                    }
            }
            + documents.macs.map { "mac \($0.mac.rawValue)" }
            + documents.failures.map { "failure \($0.source)" }
    }

    @Test
    func parallelReadKeepsOrderOfFilesAndFailures() async throws {
        let key = try Self.key()
        let base = InMemoryStateStore(files: Self.files(device: key.keyID).mapValues { Data($0.utf8) })
        let shuffled = ShuffledStore(base)
        let documents = try await StateReader(store: shuffled, device: key.keyID).read()
        let first = "repos/\(Self.alpha)/epics/\(Self.running)"
        #expect(documents.repositories.map(\.repo.rawValue) == [Self.alpha])
        #expect(documents.epics.map(\.epic.id.rawValue) == [Self.running, Self.asking, Self.merged, Self.other])
        #expect(documents.epics.first?.jobs.map(\.id.rawValue) == [Self.jobID("JA1"), Self.jobID("JA4")])
        // 失敗は、直列に読んでいたときと同じ順（リポジトリ・epic の順 → ジョブ → 試行 → 次の epic → Mac → 司令塔 → 送った意図）
        #expect(documents.failures.map(\.source) == [
            "\(first)/jobs/\(Self.jobID("JA2")).json",
            "\(first)/jobs/\(Self.jobID("JA3")).json",
            "\(first)/attempts/\(Self.jobID("JA1"))/1.json",
            "repos/\(Self.alpha)/epics/\(Self.asking)/questions.json",
            "macs/mac-b.json",
            "commander.json",
            "intents/\(key.keyID.rawValue)/01JCJ0C0000000000000000001.json"
        ])
        #expect(documents.failures[1].message == StateReader.misplaced)
        // 終わった epic のジョブは読まない
        #expect(await !shuffled.reads.contains { $0.contains(Self.jobID("JA5")) })
        // 並んで読んでいる
        #expect(await shuffled.maxInFlight > 1)

        // 待ちの無い置き場所で読んでも、同じものが同じ順に並ぶ
        let plain = try await StateReader(store: ShuffledStore(base, delays: false), device: key.keyID).read()
        #expect(Self.summary(plain) == Self.summary(documents))
    }

    @Test
    func serviceKeepsConcurrentRequestsWithinLimit() async throws {
        let key = try Self.key()
        var files = Self.files(device: key.keyID)
        let epic = "repos/\(Self.beta)/epics/\(Self.other)"
        for number in 10..<40 {
            let id = Self.jobID("J\(number)")
            files["\(epic)/jobs/\(id).json"] = Self.job(id, repo: Self.beta, epic: Self.other)
        }
        let probe = ShuffledStore(InMemoryStateStore(files: files.mapValues { Data($0.utf8) }))
        let service = StateClientService(store: probe, key: key)
        _ = try await service.fetchSnapshot()
        let maximum = await probe.maxInFlight
        #expect(maximum > 1)
        #expect(maximum <= StateClientService.concurrentRequests)
    }

    @Test
    func sentIntentsAndRecordsAreReadOnce() async throws {
        let key = try Self.key()
        let base = InMemoryStateStore(files: StateClientServiceTests.askingEpic().mapValues { Data($0.utf8) })
        let store = ShuffledStore(base, delays: false)
        let service = StateClientService(store: store, key: key)
        _ = try await service.fetchSnapshot()
        try await service.perform(.answer(epicID: StateClientServiceTests.epicID, questionID: "Q1", optionID: "日ごと", note: ""))
        let sent = try #require(try await base.listAll("intents/\(key.keyID.rawValue)")?.first)
        let nonce = try #require(ULID(rawValue: String(sent.name.dropLast(".json".count))))
        let consumed = StatePath.consumed(device: key.keyID, nonce: nonce)
        let record = #"{"v":1,"kind":"answer","consumedAt":"2027-01-15T08:00:00Z","result":"accepted"}"#
        await base.put(consumed, data: Data(record.utf8))

        let first = try await service.fetchSnapshot()
        #expect(first.sentIntents.first?.state == .accepted(at: Timestamp(rawValue: "2027-01-15T08:00:00Z")!.date))
        // 2 回目からは、一覧の sha が同じなので読み直さない（結果は同じ）
        let second = try await service.fetchSnapshot()
        #expect(second.sentIntents == first.sentIntents)
        #expect(await store.readCount(of: sent.path) == 1)
        #expect(await store.readCount(of: consumed) == 1)

        // 新しく送ったものだけを読む
        try await service.perform(.answer(epicID: StateClientServiceTests.epicID, questionID: "Q1", optionID: "週ごと", note: ""))
        let third = try await service.fetchSnapshot()
        #expect(third.sentIntents.count == 2)
        #expect(await store.readCount(of: sent.path) == 1)
        let newer = try #require(try await base.listAll("intents/\(key.keyID.rawValue)")?.first { $0.path != sent.path })
        #expect(await store.readCount(of: newer.path) == 1)
    }
}
