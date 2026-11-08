@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import Testing

/// 人がする作業（file）で渡されたファイルを、それに依存するタスクの実装のときに置いて Claude に読ませる
struct ImplementTaskHandoverTests {
    typealias Fixture = TaskJobFixture

    static let plist = Data("<plist><dict><key>PROJECT_ID</key><string>askhub-sandbox</string></dict></plist>".utf8)
    static let name = "GoogleService-Info.plist"

    static func attachment(of data: Data = plist) -> RequestAttachment {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return RequestAttachment(number: 1, name: name, size: data.count, sha256: digest)
    }

    /// 署名した `humanTaskDone`（h1・ファイル付き）と中身を置き、t2 が h1 に依存するゴールにする。
    /// `signer` を変えると、ワーカーが信用しない鍵で署名した意図になる
    @discardableResult
    static func handOver(
        _ fixture: Fixture,
        content: Data = plist,
        signer: P256.Signing.PrivateKey? = nil,
        recorded: RequestAttachment = attachment()
    ) async throws -> IntentReference {
        let key = signer ?? fixture.key
        let keyID = IntentSignature.keyID(publicKeyDER: key.publicKey.derRepresentation)
        let nonce = ULID.generate(at: Fixture.start)
        let target = HumanTaskTarget(repo: Fixture.repo, epic: Fixture.epic, task: "h1", goalVersion: 1)
        let done = HumanTaskDoneIntent(target: target, file: attachment(), intent: IntentReference(keyId: keyID, nonce: nonce))
        let envelope = IntentEnvelope(
            kind: HumanTaskDoneIntent.kind,
            repo: Fixture.repo,
            target: target.target,
            targetVersion: target.targetVersion,
            payload: done.payload,
            issuedAt: Timestamp(Fixture.start),
            nonce: nonce,
            keyId: keyID
        )
        let value = try envelope.jsonValue()
        let stored = JSONValue.object(["envelope": value, "sig": .string(try IntentSignature.sign(envelope: value, with: key))])
        await fixture.store.put(StatePath.intent(device: keyID, nonce: nonce), data: CanonicalJSON.data(for: stored))
        await fixture.store.put(StatePath.attachment(device: keyID, nonce: nonce, number: 1), data: content)
        try await fixture.files.update(GoalFile.self, at: StatePath.goal(Fixture.repo, Fixture.epic), message: "h1") { goal in
            goal.tasks[1].dependsOn.append("h1")
            goal.humanTasks = [
                GoalFile.HumanTask(
                    id: "h1",
                    title: "Firebase のプロジェクトを作る",
                    why: "SDK が設定ファイルを読む",
                    steps: ["GoogleService-Info.plist を落とす"],
                    handover: .init(kind: .file),
                    state: .done,
                    done: .init(intent: done.intent, at: Timestamp(Fixture.start), file: recorded)
                )
            ]
            return true
        }
        return done.intent
    }

    private func implement(_ fixture: Fixture, runner: FakeTaskRunner) async throws -> JobResult {
        try await ImplementTaskRunner(environment: try fixture.environment(runner)).execute(fixture.job(.implementTask, "02"))
    }

    @Test func placesHandedOverFileAndTellsClaude() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        try await Self.handOver(fixture)
        let runner = ImplementTaskRunnerTests.editing(fixture.git, [FakeTaskRunner.done()])
        let result = try await implement(fixture, runner: runner)
        #expect(result.failure == nil)

        // epic の作業場所の外（タスクごとのフォルダ）に `<作業の id>/<名前>` で置き、そのフォルダを Claude が読めるようにする
        let directory = fixture.git.handoverRoot.appendingPathComponent("\(Fixture.epic.rawValue)/t2", isDirectory: true)
        let file = directory.appendingPathComponent("h1/\(Self.name)")
        #expect(try Data(contentsOf: file) == Self.plist)
        let call = try #require(runner.calls.first)
        #expect(call.additionalDirectories == [directory])
        #expect(call.prompt.contains("## 人がする作業で渡されたファイル\n<handover>\n- h1（Firebase のプロジェクトを作る）: \(file.path)\n</handover>"))
        #expect(fixture.git.current.calls.contains("handoverDirectory t2"))
    }

    /// 前提に file の作業が無ければ、フォルダを作らず、節も出さない
    @Test func noHandoverWithoutFileTasks() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        let runner = ImplementTaskRunnerTests.editing(fixture.git, [FakeTaskRunner.done()])
        #expect(try await implement(fixture, runner: runner).failure == nil)
        let call = try #require(runner.calls.first)
        #expect(call.additionalDirectories.isEmpty)
        #expect(!call.prompt.contains("<handover>"))
        #expect(!fixture.git.current.calls.contains { $0.hasPrefix("handoverDirectory") })
    }

    /// 受け付けた後に中身が置き換えられた（大きさかハッシュが署名した意図と合わない）ら、渡さずに失敗にする
    @Test func refusesReplacedFile() async throws {
        let fixture = Fixture()
        try await fixture.prepare()
        try await Self.handOver(fixture, content: Data("置き換えた中身".utf8))
        let runner = FakeTaskRunner([FakeTaskRunner.done()])
        let result = try await implement(fixture, runner: runner)
        #expect(result.failure?.failureClass == .unexpected)
        #expect(result.failure?.message == "人がする作業 h1 で渡されたファイル（\(Self.name)）の大きさかハッシュが、署名した意図と合わないので、Claude に渡さない")
        #expect(runner.calls.isEmpty)
        #expect(!fixture.git.current.calls.contains { $0.hasPrefix("handoverDirectory") })
    }

    /// 置き場所はタスクごと（`epics/<epic>/handover/<タスク>`）。置き直すたびに空にし、epic の作業場所と一緒に消える
    @Test func handoverDirectoryIsPerTaskAndRemovedWithEpic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandoverTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = GitRepositoryWorkspace(setup: .init(root: root, credentialHelper: "!true"), runner: ProcessCommandRunner())
        let directory = try await workspace.handoverDirectory(epic: Fixture.epic, task: "t2")
        let expected = root.appendingPathComponent("epics/\(Fixture.epic.rawValue)/handover/t2")
        #expect(directory.standardizedFileURL == expected.standardizedFileURL)
        try Data("前の試行".utf8).write(to: directory.appendingPathComponent("old.plist"))
        let again = try await workspace.handoverDirectory(epic: Fixture.epic, task: "t2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: again.path).isEmpty)
        await #expect(throws: WorkspaceError.self) { try await workspace.handoverDirectory(epic: Fixture.epic, task: "../t2") }
        try await workspace.removeEpic(Fixture.repo, epic: Fixture.epic, branch: Fixture.branches.epic)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// 信用しない鍵で署名した意図・ゴールの記録と合わない意図からは渡さない（ジョブの元の意図ではなく、渡した人の意図を確かめる）
    @Test func refusesUntrustedOrMismatchedIntent() async throws {
        let message = "人がする作業 h1 で渡されたファイルの意図が無い・署名が合わない・ゴールの記録と合わないので、Claude に渡さない"
        let untrusted = Fixture()
        try await untrusted.prepare()
        try await Self.handOver(untrusted, signer: P256.Signing.PrivateKey())
        var runner = FakeTaskRunner([FakeTaskRunner.done()])
        #expect(try await implement(untrusted, runner: runner).failure?.message == message)
        #expect(runner.calls.isEmpty)

        // ゴールの記録のファイルが、署名した意図のものと違う
        let mismatched = Fixture()
        try await mismatched.prepare()
        try await Self.handOver(mismatched, recorded: Self.attachment(of: Data("別のファイル".utf8)))
        runner = FakeTaskRunner([FakeTaskRunner.done()])
        #expect(try await implement(mismatched, runner: runner).failure?.message == message)
        #expect(runner.calls.isEmpty)
    }
}
