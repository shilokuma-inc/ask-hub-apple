import Foundation

/// 最新情報の下書き（release ブランチの `AppStore/whats-new-draft.json`）。リリース準備（`release-prepare.yml`）が、前のタグから入った PR で作る。
/// 確定（`release-notes.yml`）すると `AppStore/metadata/<言語>.json` の `whatsNew` に書かれ、このファイルは消える。形は `docs/release.md` の「最新情報の下書き」
public struct WhatsNewDraft: Sendable, Equatable, Decodable {
    /// 下書きの元にした PR
    public struct PullRequest: Sendable, Equatable, Decodable {
        public var number: Int
        /// 【TYPE】を外したタイトル
        public var title: String
        /// 【TYPE】の中（`FIX` など）。無ければ `nil`
        public var type: String?
        public var url: URL?
        public var mergedAt: Date?
        /// epic の PR から開いたときの、epic の PR の番号
        public var epic: Int?
        /// 本文に載せたか（CI・ドキュメントだけの PR などは `false`）
        public var included: Bool

        public init(number: Int, title: String, type: String?, url: URL?, mergedAt: Date?, epic: Int?, included: Bool) {
            self.number = number
            self.title = title
            self.type = type
            self.url = url
            self.mergedAt = mergedAt
            self.epic = epic
            self.included = included
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: DraftPullRequestKeys.self)
            number = try container.decode(Int.self, forKey: .number)
            title = try container.decode(String.self, forKey: .title)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            // URL と日時は表示にしか使わないので、読めなくても下書きそのものは読む
            url = (try? container.decodeIfPresent(String.self, forKey: .url)).flatMap(URL.init(string:))
            mergedAt = try? container.decodeIfPresent(Date.self, forKey: .mergedAt)
            epic = try container.decodeIfPresent(Int.self, forKey: .epic)
            included = try container.decode(Bool.self, forKey: .included)
        }
    }

    /// 前のタグ、または下書きを作ったときの `develop`
    public struct Commit: Sendable, Equatable, Decodable {
        /// `base` ではタグ（`v1.0.0`）、`head` では ref（`origin/develop`）
        public var name: String
        public var sha: String

        public init(name: String, sha: String) {
            self.name = name
            self.sha = sha
        }
    }

    /// 読める形の版
    public static let supportedSchemaVersion = 1
    /// リポジトリの中の場所（release ブランチにだけある）
    public static let path = "AppStore/whats-new-draft.json"

    public var schemaVersion: Int
    /// リリースのバージョン（release ブランチの `<v>` と同じはず。違う形でも文字列のまま持つ）
    public var version: String
    public var generatedAt: Date?
    /// 前のタグ。初めてのリリースでは `nil`
    public var base: Commit?
    public var head: Commit?
    /// 前のタグが無い（初めてのリリース）
    public var initial: Bool
    /// 言語コード → 本文
    public var whatsNew: [String: String]
    /// 4000 字に収まらず「・ほか N 件」にまとめた PR の数
    public var omitted: Int
    public var pullRequests: [PullRequest]
    /// 作ったときの説明（人に向けた文。表示するだけ）
    public var messages: [String]

    public init(
        schemaVersion: Int = Self.supportedSchemaVersion,
        version: String,
        generatedAt: Date?,
        base: Commit?,
        head: Commit?,
        initial: Bool,
        whatsNew: [String: String],
        omitted: Int,
        pullRequests: [PullRequest],
        messages: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.generatedAt = generatedAt
        self.base = base
        self.head = head
        self.initial = initial
        self.whatsNew = whatsNew
        self.omitted = omitted
        self.pullRequests = pullRequests
        self.messages = messages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        version = try container.decode(String.self, forKey: .version)
        generatedAt = try? container.decodeIfPresent(Date.self, forKey: .generatedAt)
        base = try container.decodeIfPresent(CommitNode.self, forKey: .base).map { Commit(name: $0.tag ?? $0.ref ?? "", sha: $0.sha) }
        head = try container.decodeIfPresent(CommitNode.self, forKey: .head).map { Commit(name: $0.ref ?? $0.tag ?? "", sha: $0.sha) }
        initial = try container.decodeIfPresent(Bool.self, forKey: .initial) ?? (base == nil)
        whatsNew = try container.decode([String: String].self, forKey: .whatsNew)
        omitted = try container.decodeIfPresent(Int.self, forKey: .omitted) ?? 0
        pullRequests = try container.decodeIfPresent([PullRequest].self, forKey: .pullRequests) ?? []
        messages = try container.decodeIfPresent([String].self, forKey: .messages) ?? []
    }

    /// JSON の本文から読む。`schemaVersion` が知らない値なら、ほかのキーは読まずに `ReleaseReadError.unsupportedDraftSchema` を投げる
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let schema: SchemaProbe
        do {
            schema = try decoder.decode(SchemaProbe.self, from: data)
        } catch {
            throw ReleaseReadError.invalidContent(path: path)
        }
        guard schema.schemaVersion == supportedSchemaVersion else {
            throw ReleaseReadError.unsupportedDraftSchema(schema.schemaVersion)
        }
        do {
            return try decoder.decode(Self.self, from: data)
        } catch {
            throw ReleaseReadError.invalidContent(path: path)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, generatedAt, base, head, initial, whatsNew, omitted, pullRequests, messages
    }

    private struct CommitNode: Decodable {
        let tag: String?
        let ref: String?
        let sha: String
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }
}

/// `WhatsNewDraft.PullRequest` のキー（型の入れ子を 1 段に保つため外に置く）
private enum DraftPullRequestKeys: String, CodingKey {
    case number, title, type, url, mergedAt, epic, included
}
