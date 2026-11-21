import Foundation

extension GitHubContentsStore {
    /// ディレクトリを、Git Data API の 1 つのコミットでまとめて移す。ファイルの中身（blob）は同じものを指すだけで、取り直さない。
    ///
    /// ブランチの先頭を読み、移す元の下のファイルを tree から並べ、先頭の tree に「元を消して先に置く」を重ねた tree とコミットを作って、
    /// ブランチを進める（早送りだけ）。読んだ後にほかの書き手が書いていれば、ブランチを進められずに `conflict`（何も変わらない）。
    /// 書き込みの予算は、内容を作る要求（tree・コミット・ブランチの更新）の 3 回を数える
    public func move(_ moves: [StateMove], message: String) async throws(StateStoreError) {
        guard moves.allSatisfy({ StatePathCheck.isSafe($0.from) && StatePathCheck.isSafe($0.to) }) else { throw .invalidPath }
        let branch = try await branchName()
        let head = try await decode(RefPayload.self, from: try await request("GET", "git/ref/heads/\(branch)")).object.sha
        let base = try await decode(CommitPayload.self, from: try await request("GET", "git/commits/\(head)")).tree.sha
        var entries: [MoveTreeEntry] = []
        // 同じ呼び出しで先に置くと決めたファイル。後の移動の先と重なれば（同じパス・その下・祖先がファイル）、何も書かずに断る
        var reserved: Set<String> = []
        for move in moves {
            guard let sha = try await treeSHA(of: move.from) else { continue }
            let parts = move.to.split(separator: "/")
            let ancestors = parts.indices.dropLast().map { parts[...$0].joined(separator: "/") }
            guard !reserved.contains(where: { $0 == move.to || $0.hasPrefix(move.to + "/") }),
                  !ancestors.contains(where: reserved.contains), try await !exists(move.to) else { throw .conflict }
            for file in try await tree(sha: sha, under: move.from, recursive: true) {
                let destination = move.to + file.path.dropFirst(move.from.count)
                entries.append(MoveTreeEntry(path: file.path, sha: nil))
                entries.append(MoveTreeEntry(path: destination, sha: file.sha))
                reserved.insert(destination)
            }
        }
        guard !entries.isEmpty else { return }
        let treeBody = TreeBody(baseTree: base, tree: entries)
        let tree = try await decode(ShaPayload.self, from: try await request("POST", "git/trees", body: treeBody))
        let commitBody = CommitBody(message: message, tree: tree.sha, parents: [head])
        let commit = try await decode(ShaPayload.self, from: try await request("POST", "git/commits", body: commitBody))
        do {
            _ = try await request("PATCH", "git/refs/heads/\(branch)", body: RefBody(sha: commit.sha, force: false))
        } catch let .unexpected(status: 422, message) where message?.localizedCaseInsensitiveContains("fast forward") == true {
            // 早送りにならない（読んだ後にほかの書き手が書いた）。ほかの 422（ルールで断られたなど）は、理由を残すためそのまま伝える
            throw .conflict
        }
    }

    /// 1 つの tree の要求に入れる文字の大きさの上限（UTF-8 のバイト数）。超えたら tree を分け、前の tree を元に次の tree を作る
    static let treeChunkBytes = 8_000_000

    /// テキストのファイルを、Git Data API の 1 つのコミットでまとめて書く（あれば上書き）。
    ///
    /// ブランチの先頭の tree を元に、ファイルの中身（`content`。UTF-8 の文字だけ持てる）を重ねた tree とコミットを作り、ブランチを早送りで進める。
    /// 読んだ後にほかの書き手が書いて早送りにならなければ、読み直して 3 回までやり直す（足すファイルは、ほかの書き手のものと重ならない）。
    /// 書き込みの予算は、内容を作る要求（tree・コミット・ブランチの更新）を数える。ファイルが何枚でも、1 回で 3 件（大きければ tree が増える）
    public func writeTextFiles(_ files: [String: String], message: String) async throws(StateStoreError) {
        guard !files.isEmpty else { return }
        guard files.keys.allSatisfy(StatePathCheck.isSafe) else { throw .invalidPath }
        let branch = try await branchName()
        let chunks = Self.chunks(files)
        for attempt in 1...3 {
            let head = try await decode(RefPayload.self, from: try await request("GET", "git/ref/heads/\(branch)")).object.sha
            var tree = try await decode(CommitPayload.self, from: try await request("GET", "git/commits/\(head)")).tree.sha
            for chunk in chunks {
                let body = TextTreeBody(baseTree: tree, tree: chunk.map { TextTreeEntry(path: $0.key, content: $0.value) })
                tree = try await decode(ShaPayload.self, from: try await request("POST", "git/trees", body: body)).sha
            }
            let commitBody = CommitBody(message: message, tree: tree, parents: [head])
            let commit = try await decode(ShaPayload.self, from: try await request("POST", "git/commits", body: commitBody))
            do {
                _ = try await request("PATCH", "git/refs/heads/\(branch)", body: RefBody(sha: commit.sha, force: false))
                return
            } catch let .unexpected(status: 422, message) where message?.localizedCaseInsensitiveContains("fast forward") == true {
                // 早送りにならない（読んだ後にほかの書き手が書いた）。読み直してやり直す
                if attempt == 3 { throw .conflict }
            }
        }
    }

    /// パスの順に並べ、UTF-8 で `treeChunkBytes` ごとに分ける（1 つのファイルが上限より大きくても、そのファイルだけの塊にする）
    static func chunks(_ files: [String: String]) -> [[(key: String, value: String)]] {
        var chunks: [[(key: String, value: String)]] = []
        var current: [(key: String, value: String)] = []
        var size = 0
        for file in files.sorted(by: { $0.key < $1.key }) {
            let bytes = file.value.utf8.count + file.key.utf8.count
            if !current.isEmpty, size + bytes > treeChunkBytes {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(file)
            size += bytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// パスに何か（ディレクトリかファイル）があるか
    private func exists(_ path: String) async throws(StateStoreError) -> Bool {
        do throws(StateStoreError) {
            if try await treeSHA(of: path) != nil { return true }
            return try await read(path) != nil
        } catch .wrongKind {
            // 親かそのものがファイル
            return true
        }
    }

    /// 書き込むブランチ。決めていなければ、リポジトリの既定のブランチ
    private func branchName() async throws(StateStoreError) -> String {
        if let branch { return branch }
        let name = try await decode(RepositoryPayload.self, from: try await request("GET", nil)).defaultBranch
        // git の ref の名前の決まり（`git check-ref-format`）のうち、URL のパスに関わるものを確かめる。
        // パスに入れるときは、要求を組み立てるところ（`appendingPathComponent`）が要る文字をエンコードする
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        guard !name.isEmpty, !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix("."),
              !name.contains(".."), !name.contains("@{"), !name.contains("//"), name.rangeOfCharacter(from: forbidden) == nil else {
            throw .unexpected(status: 200, message: "既定のブランチの名前の形が違う")
        }
        return name
    }

    /// リポジトリの API（`apiPath` が nil ならリポジトリそのもの）に送る。内容を作る要求は、書き込みの予算に数える
    private func request(
        _ method: String,
        _ apiPath: String?,
        body: (some Encodable)? = String?.none
    ) async throws(StateStoreError) -> Data {
        var request = try await makeRequest(apiPath: apiPath ?? "", query: [])
        if apiPath == nil, let url = request.url?.absoluteString, url.hasSuffix("/") {
            request.url = URL(string: String(url.dropLast()))
        }
        request.httpMethod = method
        if let body {
            try await budget?.reserve(now: now())
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw .unexpected(status: 0, message: "要求の本文を作れない")
            }
        }
        let (responseBody, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 422 {
                throw .unexpected(status: 422, message: String(bytes: responseBody.prefix(200), encoding: .utf8))
            }
            throw StateStoreError.classify(response, body: responseBody, now: now())
        }
        return responseBody
    }

    private func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) throws(StateStoreError) -> Payload {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw .unexpected(status: 200, message: "応答を読めない（\(Payload.self)）")
        }
        return payload
    }
}

/// tree に重ねる 1 つのファイル。`sha` が nil なら消す（JSON では `null` を書く）
private struct MoveTreeEntry: Encodable {
    let path: String
    let sha: String?

    enum CodingKeys: String, CodingKey {
        case path, mode, type, sha
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        // 状態リポジトリのファイルは JSON と画像だけで、実行できるファイルは無い
        try container.encode("100644", forKey: .mode)
        try container.encode("blob", forKey: .type)
        try container.encode(sha, forKey: .sha)
    }
}

/// tree に重ねる 1 つのテキストのファイル（中身を渡し、GitHub が blob を作る）
private struct TextTreeEntry: Encodable {
    let path: String
    let content: String

    enum CodingKeys: String, CodingKey {
        case path, mode, type, content
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode("100644", forKey: .mode)
        try container.encode("blob", forKey: .type)
        try container.encode(content, forKey: .content)
    }
}

private struct TextTreeBody: Encodable {
    let baseTree: String
    let tree: [TextTreeEntry]

    enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }
}

private struct TreeBody: Encodable {
    let baseTree: String
    let tree: [MoveTreeEntry]

    enum CodingKeys: String, CodingKey {
        case baseTree = "base_tree"
        case tree
    }
}

private struct CommitBody: Encodable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct RefBody: Encodable {
    let sha: String
    let force: Bool
}

private struct ShaPayload: Decodable {
    let sha: String
}

private struct RefPayload: Decodable {
    let object: ShaPayload
}

private struct CommitPayload: Decodable {
    let tree: ShaPayload
}

private struct RepositoryPayload: Decodable {
    let defaultBranch: String

    enum CodingKeys: String, CodingKey {
        case defaultBranch = "default_branch"
    }
}
