import Foundation

/// リリースの読み取り。アプリの「リリース準備」と進み具合の画面が使う。テストやデモモードでは差し替える
public protocol ReleaseReading: Sendable {
    /// release ブランチとタグの一覧
    func refs(repository: String) async throws -> ReleaseRefs
    /// `ref` の `Configs/Project.xcconfig` の `MARKETING_VERSION`
    func marketingVersion(repository: String, ref: String) async throws -> MarketingVersion
    /// `version` の release ブランチの最新情報の下書き。無ければ `nil`
    func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft?
    /// `version` の release ブランチの最新情報が、下書きのままか確定済みか
    func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes
}

/// GitHub の REST API（Git refs・Contents）でリリースの状態を読む。アプリは GitHub だけを見る（App Store Connect は見られない）。
/// トークンには Contents の Read が要る（Discussion #605。アプリからは push・タグ・Release の作成をしない）
public struct GitHubReleaseReader: ReleaseReading {
    /// `MARKETING_VERSION` を読むブランチ（release ブランチを切る元）
    public static let developBranch = "develop"
    /// `MARKETING_VERSION` を書いているファイル
    public static let xcconfigPath = "Configs/Project.xcconfig"
    /// App Store に載せる言語の一覧
    public static let languagesPath = "AppStore/languages.json"

    /// 言語ごとのメタデータのファイル（`AppStore/metadata/ja.json`）
    public static func metadataPath(language: String) -> String {
        "AppStore/metadata/\(language).json"
    }

    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    /// release ブランチ（`git/matching-refs/heads/release/`）と `v` で始まるタグ（`git/matching-refs/tags/v`）を、ページングを最後まで追って読む
    ///
    /// - Throws: `ReleaseReadError.repositoryNotFound`（404）・`.permissionDenied`（レート制限でない 403）
    public func refs(repository: String) async throws -> ReleaseRefs {
        let branches = try await matchingRefs(repository: repository, prefix: "heads/\(ReleaseVersion.branchPrefix)")
        let tags = try await matchingRefs(repository: repository, prefix: "tags/\(ReleaseVersion.tagPrefix)")
        return ReleaseRefs(
            branches: branches.map { ReleaseRef(name: $0.name, sha: $0.sha, version: ReleaseVersion(branch: $0.name)) },
            tags: tags.map { ReleaseRef(name: $0.name, sha: $0.sha, version: ReleaseVersion(tag: $0.name)) }
        )
    }

    /// `ref`（既定は `develop`）の `Configs/Project.xcconfig` の `MARKETING_VERSION`。次のマイナーは `nextMinor`。
    /// 入力したバージョンが `MARKETING_VERSION` より大きいかなどの判定はここではしない（ワークフローの入力の検査が正本）
    ///
    /// - Throws: `ReleaseReadError.fileNotFound`（ファイルかブランチが無い）・`.marketingVersionNotFound`・`.permissionDenied`・`.invalidContent`
    public func marketingVersion(repository: String, ref: String = Self.developBranch) async throws -> MarketingVersion {
        guard let data = try await fileContents(repository: repository, path: Self.xcconfigPath, ref: ref) else {
            throw ReleaseReadError.fileNotFound(path: Self.xcconfigPath, ref: ref)
        }
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw ReleaseReadError.invalidContent(path: Self.xcconfigPath)
        }
        guard let marketingVersion = MarketingVersion.parse(xcconfig: text) else {
            throw ReleaseReadError.marketingVersionNotFound
        }
        return marketingVersion
    }

    /// `release/<version>` の `AppStore/whats-new-draft.json`。ファイル（か release ブランチ）が無ければ `nil`
    ///
    /// - Throws: `ReleaseReadError.unsupportedDraftSchema`（知らない版）・`.invalidContent`・`.permissionDenied`
    public func whatsNewDraft(repository: String, version: ReleaseVersion) async throws -> WhatsNewDraft? {
        guard let data = try await fileContents(repository: repository, path: WhatsNewDraft.path, ref: version.branchName) else {
            return nil
        }
        return try WhatsNewDraft.decode(data)
    }

    /// `release/<version>` の下書きと、`AppStore/languages.json` の各言語の `AppStore/metadata/<言語>.json` の `whatsNew` を読み、
    /// 「下書きあり（未確定）」か「確定済み」（すべての言語で `whatsNew.version` がリリースのバージョン）かを決める。
    /// 下書きの版が知らない値のときは投げずに `.unsupportedDraft` で返す（確定済みの本文は読む）
    ///
    /// - Throws: `ReleaseReadError.invalidContent`・`.permissionDenied`
    public func releaseNotes(repository: String, version: ReleaseVersion) async throws -> ReleaseNotes {
        let ref = version.branchName
        let languages = try await languages(repository: repository, ref: ref)
        var whatsNew: [String: ConfirmedWhatsNew] = [:]
        for language in languages {
            let path = Self.metadataPath(language: language)
            guard let data = try await fileContents(repository: repository, path: path, ref: ref) else {
                continue
            }
            guard let metadata = try? JSONDecoder().decode(MetadataFile.self, from: data) else {
                throw ReleaseReadError.invalidContent(path: path)
            }
            whatsNew[language] = metadata.whatsNew
        }
        let status: ReleaseNotes.Status
        do {
            if let draft = try await whatsNewDraft(repository: repository, version: version) {
                status = .draft(draft)
            } else {
                status = ReleaseNotes.statusWithoutDraft(languages: languages, whatsNew: whatsNew, version: version)
            }
        } catch ReleaseReadError.unsupportedDraftSchema(let schemaVersion) {
            status = .unsupportedDraft(schemaVersion: schemaVersion)
        }
        return ReleaseNotes(version: version, status: status, languages: languages, whatsNew: whatsNew)
    }

    // MARK: - 共通

    /// `AppStore/languages.json` の `language`。ファイルが無ければ空。パスに使うので、英数字・`-`・`_` だけの言語コードに限る
    private func languages(repository: String, ref: String) async throws -> [String] {
        guard let data = try await fileContents(repository: repository, path: Self.languagesPath, ref: ref) else {
            return []
        }
        guard let file = try? JSONDecoder().decode(LanguagesFile.self, from: data) else {
            throw ReleaseReadError.invalidContent(path: Self.languagesPath)
        }
        var seen = Set<String>()
        return file.languages.map(\.language).filter { language in
            !language.isEmpty
                && language.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
                && seen.insert(language).inserted
        }
    }

    /// `git/matching-refs/<prefix>` を最後のページまで読む。名前は `refs/heads/`・`refs/tags/` を外す。
    /// 空のリポジトリ（409 `Git Repository is empty`）は空の一覧として扱う
    private func matchingRefs(repository: String, prefix: String) async throws -> [(name: String, sha: String)] {
        let nodes: [RefNode]
        do {
            nodes = try await client.getAllPages("repos/\(repository)/git/matching-refs/\(prefix)", of: RefNode.self)
        } catch GitHubError.http(status: 404, _) {
            throw ReleaseReadError.repositoryNotFound
        } catch GitHubError.http(status: 403, _) {
            throw ReleaseReadError.permissionDenied
        } catch GitHubError.http(status: 409, _) {
            return []
        }
        let fullPrefix = "refs/"
        return nodes.compactMap { node in
            guard node.ref.hasPrefix(fullPrefix + prefix) else {
                return nil
            }
            // refs/heads/release/1.1.0 → release/1.1.0、refs/tags/v1.1.0 → v1.1.0
            let kind = prefix.prefix { $0 != "/" }
            return (String(node.ref.dropFirst(fullPrefix.count + kind.count + 1)), node.object.sha)
        }
    }

    /// Contents API でファイルの中身を読む。404（ファイルかブランチが無い）は `nil`
    private func fileContents(repository: String, path: String, ref: String) async throws -> Data? {
        let node: ContentNode
        do {
            node = try await client.get(
                "repos/\(repository)/contents/\(path)",
                query: [URLQueryItem(name: "ref", value: ref)],
                as: ContentNode.self
            )
        } catch GitHubError.http(status: 404, _) {
            return nil
        } catch GitHubError.http(status: 403, _) {
            throw ReleaseReadError.permissionDenied
        } catch is DecodingError {
            // ディレクトリは配列で返る
            throw ReleaseReadError.invalidContent(path: path)
        }
        // 1 MB を超えるファイルは encoding が none で content が空になる（読むファイルはどれも小さいので、来たら読めないものとする）
        guard node.type == "file", node.encoding == "base64", let content = node.content,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw ReleaseReadError.invalidContent(path: path)
        }
        return data
    }
}

// MARK: - レスポンスの形

private struct RefNode: Decodable {
    struct Object: Decodable {
        let sha: String
    }

    let ref: String
    let object: Object
}

private struct ContentNode: Decodable {
    let type: String
    let encoding: String?
    let content: String?
}

private struct LanguagesFile: Decodable {
    struct Language: Decodable {
        let language: String
    }

    let languages: [Language]
}

private struct MetadataFile: Decodable {
    let whatsNew: ConfirmedWhatsNew?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // whatsNew が無い・形が違う（前の形の文字列など）ときは、確定していないものとして扱う
        whatsNew = try? container.decodeIfPresent(ConfirmedWhatsNew.self, forKey: .whatsNew)
    }

    private enum CodingKeys: String, CodingKey {
        case whatsNew
    }
}
