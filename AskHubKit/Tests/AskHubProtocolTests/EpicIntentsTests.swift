@testable import AskHubProtocol
import Foundation
import Testing

/// 依頼・開始・ゴールの修正・取り下げ・やり直し・やめるの人の意図の形
struct EpicIntentsTests {
    /// 種類ごとの、例のファイルと読み方
    struct Kind: Sendable, CustomTestStringConvertible {
        let vectors: String
        let kind: String
        let target: IntentEnvelope.Target?
        let targetVersion: String?
        /// 読めたら、書き直した payload を返す
        let read: @Sendable (IntentEnvelope) throws -> [String: JSONValue]

        var testDescription: String { kind }
    }

    static let epic = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let job = ULID(rawValue: "01JCJ0B0000000000000000001")!
    static let jobTarget = IntentEnvelope.Target(type: "job", epic: epic, id: job.rawValue)
    static let kinds: [Kind] = [
        Kind(vectors: "payloads/request.json", kind: "request", target: nil, targetVersion: nil) {
            try RequestIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/startEpic.json", kind: "startEpic", target: .init(type: "epic", epic: epic), targetVersion: "3") {
            try StartEpicIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/reviseGoal.json", kind: "reviseGoal", target: .init(type: "epic", epic: epic), targetVersion: "3") {
            try ReviseGoalIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/decideSplit.json", kind: "decideSplit", target: .init(type: "epic", epic: epic), targetVersion: "3") {
            try DecideSplitIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/addRepository.json", kind: "addRepository", target: nil, targetVersion: nil) {
            try AddRepositoryIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/retry.json", kind: "retry", target: jobTarget, targetVersion: "2") {
            try RetryJobIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/giveUp.json", kind: "giveUp", target: jobTarget, targetVersion: "2") {
            try GiveUpJobIntent(envelope: $0).payload
        },
        Kind(vectors: "payloads/abandonEpic.json", kind: "abandonEpic", target: .init(type: "epic", epic: epic), targetVersion: nil) {
            try AbandonEpicIntent(envelope: $0).payload
        }
    ]

    private let validator = SchemaValidator(directory: Vectors.directory.deletingLastPathComponent().appendingPathComponent("schemas"))

    private func envelope(_ kind: Kind, payload: [String: JSONValue]?) -> IntentEnvelope {
        envelope(kind: kind.kind, target: kind.target, targetVersion: kind.targetVersion, payload: payload)
    }

    private func envelope(
        kind: String,
        target: IntentEnvelope.Target?,
        targetVersion: String?,
        payload: [String: JSONValue]?
    ) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox"),
            target: target,
            targetVersion: targetVersion,
            payload: payload,
            issuedAt: Timestamp(rawValue: "2026-11-03T10:00:00Z")!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
        )
    }

    @Test(arguments: kinds)
    func followsPayloadVectors(_ kind: Kind) throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Vectors.data(kind.vectors)) as? [String: Any])
        let schema = try #require(file["schema"] as? String)
        let cases = try #require(file["cases"] as? [[String: Any]])
        #expect(cases.contains { $0["read"] as? String == "valid" })
        for vector in cases {
            let name = try #require(vector["name"] as? String)
            let payload = try #require(vector["payload"])
            let errors = try validator.errors(of: payload, against: schema)
            #expect(errors.isEmpty == (vector["schemaValid"] as? Bool), "\(name): \(errors)")
            guard case let .object(object) = try JSONValue(parsing: JSONSerialization.data(withJSONObject: payload)) else {
                Issue.record("\(name): payload が object でない")
                continue
            }
            let read: String
            do {
                let rewritten = try kind.read(envelope(kind, payload: object))
                // 書き直した payload も同じものとして読め、スキーマに合う
                #expect(try kind.read(envelope(kind, payload: rewritten)) == rewritten, "\(name)")
                let value = try JSONSerialization.jsonObject(with: CanonicalJSON.data(for: .object(rewritten)))
                #expect(try validator.errors(of: value, against: schema).isEmpty, "\(name) を書き直したもの")
                read = "valid"
            } catch {
                read = "malformed"
            }
            #expect("\(name): \(read)" == "\(name): \(vector["read"] as? String ?? "")")
        }
    }

    @Test func readsRequestAttachments() throws {
        let hash = String(repeating: "a", count: 64)
        let attachment = JSONValue.object(["n": .integer(1), "name": .string("mock.png"), "size": .integer(1024), "sha256": .string(hash)])
        let payload: [String: JSONValue] = ["title": .string("ランキング"), "body": .string("日ごとに入れ替えたい"), "attachments": .array([attachment])]
        let request = try RequestIntent(envelope: envelope(kind: "request", target: nil, targetVersion: nil, payload: payload))
        #expect(request.body == "日ごとに入れ替えたい")
        #expect(request.payload["body"] == .string("日ごとに入れ替えたい"))
        // 依頼は版を持つものを対象にしないので、targetVersion があれば読まない
        #expect(throws: MalformedIntent.self) {
            try RequestIntent(envelope: envelope(kind: "request", target: nil, targetVersion: "1", payload: payload))
        }
        #expect(request.attachments == [RequestAttachment(number: 1, name: "mock.png", size: 1024, sha256: hash)])
        #expect(request.intent.nonce.rawValue == "01JCN0NCE00000000000000001")
    }

    @Test func rejectsEpicIntentsWithWrongTarget() {
        let payload: [String: JSONValue] = ["mac": .string("mac-mini")]
        let cases: [(IntentEnvelope.Target?, String?)] = [
            (nil, "3"),
            (.init(type: "question", epic: Self.epic, id: "q1"), "3"),
            (.init(type: "epic", epic: Self.epic, id: "q1"), "3"),
            (.init(type: "epic"), "3"),
            (.init(type: "epic", epic: Self.epic), nil),
            (.init(type: "epic", epic: Self.epic), "0"),
            (.init(type: "epic", epic: Self.epic), "03")
        ]
        for (target, version) in cases {
            #expect(throws: MalformedIntent.self) {
                try StartEpicIntent(envelope: envelope(kind: "startEpic", target: target, targetVersion: version, payload: payload))
            }
        }
        #expect(throws: MalformedIntent.self) {
            let wrongKind = envelope(kind: "startEpic", target: .init(type: "epic", epic: Self.epic), targetVersion: "3", payload: payload)
            return try ReviseGoalIntent(envelope: wrongKind)
        }
    }

    @Test func refusesAddRepositoryWithWrongEnvelope() {
        let payload: [String: JSONValue] = ["platform": .string("apple")]
        let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")
        struct Case {
            var repo: RepositoryFullName?
            var target: IntentEnvelope.Target?
            var version: String?
        }
        // 対象のリポジトリが無い・target がある・targetVersion がある
        let cases = [Case(repo: nil), Case(repo: repo, target: .init(type: "epic", epic: Self.epic)), Case(repo: repo, version: "1")]
        for item in cases {
            let (repo, target, version) = (item.repo, item.target, item.version)
            let envelope = IntentEnvelope(
                kind: "addRepository",
                repo: repo,
                target: target,
                targetVersion: version,
                payload: payload,
                issuedAt: Timestamp(rawValue: "2026-11-03T10:00:00Z")!,
                nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!,
                keyId: KeyID(rawValue: String(repeating: "k", count: 43))!
            )
            #expect(throws: MalformedIntent.self) { try AddRepositoryIntent(envelope: envelope) }
        }
    }

    @Test func readsJobTarget() throws {
        let retry = try RetryJobIntent(envelope: envelope(
            kind: "retry", target: .init(type: "job", epic: Self.epic, id: Self.job.rawValue), targetVersion: "2", payload: [:]
        ))
        let repo = try #require(RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox"))
        #expect(retry.target == JobTarget(repo: repo, epic: Self.epic, job: Self.job, attempt: 2))
        #expect(retry.target.target == .init(type: "job", epic: Self.epic, id: Self.job.rawValue))
        #expect(retry.target.targetVersion == "2")
        // ジョブでない対象・ジョブの id が ULID でない・試行の番号でない版は読まない
        let cases: [(IntentEnvelope.Target?, String?)] = [
            (nil, "2"),
            (.init(type: "epic", epic: Self.epic), "2"),
            (.init(type: "job", epic: Self.epic), "2"),
            (.init(type: "job", id: Self.job.rawValue), "2"),
            (.init(type: "job", epic: Self.epic, id: "../job"), "2"),
            (.init(type: "job", epic: Self.epic, id: Self.job.rawValue), nil),
            (.init(type: "job", epic: Self.epic, id: Self.job.rawValue), "0")
        ]
        for (target, version) in cases {
            #expect(throws: MalformedIntent.self) {
                try RetryJobIntent(envelope: envelope(kind: "retry", target: target, targetVersion: version, payload: [:]))
            }
            #expect(throws: MalformedIntent.self) {
                try GiveUpJobIntent(envelope: envelope(kind: "giveUp", target: target, targetVersion: version, payload: [:]))
            }
        }
        // やり直しとやめるは取り違えない
        #expect(throws: MalformedIntent.self) {
            try GiveUpJobIntent(envelope: envelope(kind: "retry", target: retry.target.target, targetVersion: "2", payload: [:]))
        }
    }

    /// 取り下げは epic だけを対象にし、版を書かない
    @Test func readsAbandonEpic() throws {
        let target = IntentEnvelope.Target(type: "epic", epic: Self.epic)
        let abandon = try AbandonEpicIntent(envelope: envelope(kind: "abandonEpic", target: target, targetVersion: nil, payload: [:]))
        #expect(abandon.epic == Self.epic)
        #expect(abandon.target == target)
        let cases: [(IntentEnvelope.Target?, String?)] = [
            (nil, nil),
            (.init(type: "epic", epic: Self.epic), "1"),
            (.init(type: "epic", epic: Self.epic, id: "q1"), nil),
            (Self.jobTarget, nil)
        ]
        for (target, version) in cases {
            #expect(throws: MalformedIntent.self) {
                try AbandonEpicIntent(envelope: envelope(kind: "abandonEpic", target: target, targetVersion: version, payload: [:]))
            }
        }
    }

    @Test func readsEpicTarget() throws {
        let start = try StartEpicIntent(envelope: envelope(
            kind: "startEpic", target: .init(type: "epic", epic: Self.epic), targetVersion: "12", payload: ["mac": .string("mac-mini")]
        ))
        #expect(start.target.epic == Self.epic)
        #expect(start.target.version == 12)
        #expect(start.target.target == .init(type: "epic", epic: Self.epic))
        #expect(start.target.targetVersion == "12")
        #expect(start.mac.rawValue == "mac-mini")
    }

    /// 選んだ方で epic を分けるかが決まるので、読んだ値を直接確かめる
    @Test func readsDecideSplitChoice() throws {
        let target = IntentEnvelope.Target(type: "epic", epic: Self.epic)
        for (text, choice) in [("split", DecideSplitIntent.Choice.split), ("proceed", .proceed)] {
            let decide = try DecideSplitIntent(envelope: envelope(
                kind: "decideSplit", target: target, targetVersion: "3", payload: ["choice": .string(text)]
            ))
            #expect(decide.choice == choice)
            #expect(decide.target.version == 3)
        }
    }

    /// 依頼から決める epic の id は、決まった鍵と番号からいつも同じになる（司令塔とクライアントが同じ id を求める）
    @Test func epicIDIsDerivedFromRequestIntent() {
        let intent = IntentReference(
            keyId: KeyID(rawValue: String(repeating: "k", count: 43))!,
            nonce: ULID(rawValue: "01JCN0NCE00000000000000001")!
        )
        let id = RequestIntent.epicID(for: intent)
        #expect(id.rawValue == "01JCN0NCE0CRATSDC06XSN4DJD")
        #expect(id == RequestIntent.epicID(for: intent))
        // 番号の時刻を引き継ぎ、ほかの番号とは重ならない
        #expect(id.rawValue.prefix(10) == intent.nonce.rawValue.prefix(10))
        #expect(id != RequestIntent.epicID(for: IntentReference(keyId: intent.keyId, nonce: ULID(rawValue: "01JCN0NCE00000000000000002")!)))
    }
}
