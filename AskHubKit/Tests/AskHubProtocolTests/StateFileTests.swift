@testable import AskHubProtocol
import Foundation
import Testing

/// 状態リポジトリのファイルの型と、その例のファイル・スキーマの組
struct StateFileKind: Sendable, CustomTestStringConvertible {
    let vectors: String
    let schema: String
    /// 読んだ結果と、読めたときに書き直したもの
    let read: @Sendable (Data) -> (result: String, rewritten: Data?)

    var testDescription: String { vectors }

    static let all: [Self] = [
        .of(StateVersionFile.self, "version"),
        .of(RepositoryFile.self, "repo"),
        .of(EpicFile.self, "epic"),
        .of(JobFile.self, "job"),
        .of(AttemptFile.self, "attempt"),
        .of(MacFile.self, "mac"),
        .of(CommanderFile.self, "commander"),
        .of(DeviceFile.self, "device"),
        .of(ConsumedIntentFile.self, "consumed")
    ]

    static func of<File: StateFile>(_ type: File.Type, _ name: String) -> Self {
        Self(vectors: "state/\(name).json", schema: "state/\(name).schema.json") { data in
            do {
                let file = try StateFileCoder.decode(File.self, from: data)
                let rewritten = try StateFileCoder.encode(file)
                // 書き直したものを読み直すと、同じ値になる
                guard try StateFileCoder.decode(File.self, from: rewritten) == file else { return ("rewrittenDiffers", rewritten) }
                return ("valid", rewritten)
            } catch let error as StateFileError {
                return (StateFileTests.name(of: error), nil)
            } catch {
                return ("unexpected \(error)", nil)
            }
        }
    }
}

struct StateFileTests {
    private let validator = SchemaValidator(directory: Vectors.directory.deletingLastPathComponent().appendingPathComponent("schemas"))

    @Test(arguments: StateFileKind.all)
    func followsVectors(_ kind: StateFileKind) throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Vectors.data(kind.vectors)) as? [String: Any])
        #expect(file["schema"] as? String == kind.schema)
        let cases = try #require(file["cases"] as? [[String: Any]])
        #expect(cases.contains { $0["read"] as? String == "valid" })
        for vector in cases {
            let name = try #require(vector["name"] as? String)
            let data: Data
            if let text = vector["text"] as? String {
                data = Data(text.utf8)
            } else {
                let value = try #require(vector["value"], "\(name)")
                data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                // スキーマの判定が例のとおり
                let errors = try validator.errors(of: value, against: kind.schema)
                #expect(errors.isEmpty == (vector["schemaValid"] as? Bool), "\(name): \(errors)")
            }
            // 読む側の結果が例のとおり
            let (result, rewritten) = kind.read(data)
            #expect("\(name): \(result)" == "\(name): \(vector["read"] as? String ?? "")")
            // 読めたものを書き直すと、スキーマに合う（知らない欄は落ちる）
            if let rewritten {
                let errors = try validator.errors(of: JSONSerialization.jsonObject(with: rewritten), against: kind.schema)
                #expect(errors.isEmpty, "\(name) を書き直したもの: \(errors)")
            }
        }
    }

    @Test func schemasUseOnlySupportedKeywords() throws {
        let directory = Vectors.directory.deletingLastPathComponent().appendingPathComponent("schemas")
        let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".schema.json") }
        #expect(files.count >= 16)
        for file in files {
            try validator.checkKeywords(in: file)
        }
    }

    @Test func identifierVectorsMatchCommonSchema() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Vectors.data("identifiers.json")) as? [String: Any])
        for name in ["ulid", "repositoryFullName", "keyId", "macName", "timestamp"] {
            let vectors = try #require(file[name] as? [String: [String]])
            for text in vectors["valid"] ?? [] {
                #expect(try validator.errors(of: text, against: "common.schema.json#/$defs/\(name)").isEmpty, "\(name): \(text)")
            }
        }
    }

    @Test func signedEnvelopeMatchesSchema() throws {
        let file = try #require(try JSONSerialization.jsonObject(with: Vectors.data("intent-signature.json")) as? [String: Any])
        let envelope = try #require(file["envelope"])
        #expect(try validator.errors(of: envelope, against: "intent-envelope.schema.json").isEmpty)
        let marker: [String: Any] = ["type": "intent", "envelope": envelope, "sig": try #require(file["signature"])]
        #expect(try validator.errors(of: marker, against: "intent-marker.schema.json").isEmpty)
    }

    @Test func keyRecordsAndStoredIntentsMatchSchemas() throws {
        let ledger = try #require(try JSONSerialization.jsonObject(with: Vectors.data("key-ledger.json")) as? [String: Any])
        let cases = try #require(ledger["cases"] as? [[String: Any]])
        let chain = try #require(cases.first { $0["name"] as? String == "valid-chain" }?["records"] as? [Any])
        #expect(chain.count == 3)
        for record in chain {
            #expect(try validator.errors(of: record, against: "state/key.schema.json").isEmpty)
        }
        let stored = try #require(try JSONSerialization.jsonObject(with: Vectors.data("stored-intent.json")) as? [String: Any])
        for vector in try #require(stored["cases"] as? [[String: Any]]) {
            let errors = try validator.errors(of: try #require(vector["value"]), against: "state/stored-intent.schema.json")
            let result = vector["result"] as? String
            // 署名と時刻は読む側だけが確かめるので、形が違う例（本文のハッシュ・署名の欠け）だけがスキーマで弾かれる
            #expect(errors.isEmpty == !["bodyMismatch", "malformed"].contains(result), "\(vector["name"] ?? ""): \(errors)")
        }
    }

    @Test func encodesWithVersionSortedKeysAndNewline() throws {
        let file = try RepositoryFile(
            repo: #require(RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")),
            platform: .apple,
            addedAt: #require(Timestamp(rawValue: "2026-11-03T10:00:00Z"))
        )
        let text = try #require(String(bytes: StateFileCoder.encode(file), encoding: .utf8))
        #expect(text == """
        {
          "addedAt" : "2026-11-03T10:00:00Z",
          "maxConcurrentEpics" : 1,
          "platform" : "apple",
          "protection" : {

          },
          "repo" : "shilokuma-inc/askhub-sandbox",
          "v" : 1
        }

        """)
    }

    @Test func refusesToWriteViolations() throws {
        var file = try RepositoryFile(
            repo: #require(RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")),
            platform: .apple,
            addedAt: Timestamp(Date(timeIntervalSince1970: 0))
        )
        file.maxConcurrentEpics = 0
        #expect(throws: StateFileError.malformed("maxConcurrentEpics は 1 以上")) { try StateFileCoder.encode(file) }
    }

    @Test func pathsAreBuiltFromCheckedParts() throws {
        let repo = try #require(RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox"))
        let epic = try #require(ULID(rawValue: "01JCEP1C000000000000000001"))
        let job = try #require(ULID(rawValue: "01JCJ0B0000000000000000001"))
        let base = "repos/shilokuma-inc/askhub-sandbox"
        #expect(StatePath.version == "version.json")
        #expect(StatePath.commander == "commander.json")
        #expect(StatePath.repository(repo) == "\(base)/repo.json")
        #expect(StatePath.epic(repo, epic) == "\(base)/epics/01JCEP1C000000000000000001/epic.json")
        #expect(
            StatePath.job(repo, epic: epic, job: job) == "\(base)/epics/01JCEP1C000000000000000001/jobs/01JCJ0B0000000000000000001.json"
        )
        #expect(
            StatePath.attempt(repo, epic: epic, job: job, number: 2)
                == "\(base)/epics/01JCEP1C000000000000000001/attempts/01JCJ0B0000000000000000001/2.json"
        )
        #expect(try StatePath.mac(#require(MacName(rawValue: "mac-mini"))) == "macs/mac-mini.json")
        let device = try #require(KeyID(rawValue: "3GHenKEuXhau_ydZhSS8zpDFx5A1_I5K_ZMmfZsTw1Y"))
        #expect(StatePath.device(device) == "devices/3GHenKEuXhau_ydZhSS8zpDFx5A1_I5K_ZMmfZsTw1Y.json")
        let nonce = try #require(ULID(rawValue: "01JCN0NCE00000000000000001"))
        #expect(StatePath.key(seq: 3) == "keys/3.json")
        let file = "3GHenKEuXhau_ydZhSS8zpDFx5A1_I5K_ZMmfZsTw1Y/01JCN0NCE00000000000000001.json"
        #expect(StatePath.intent(device: device, nonce: nonce) == "intents/\(file)")
        #expect(StatePath.consumed(device: device, nonce: nonce) == "consumed/\(file)")
    }

    static func name(of error: StateFileError) -> String {
        switch error {
        case .notJSON: "notJSON"
        case .missingVersion: "missingVersion"
        case .unsupportedVersion: "unsupportedVersion"
        case .malformed: "malformed"
        }
    }
}
