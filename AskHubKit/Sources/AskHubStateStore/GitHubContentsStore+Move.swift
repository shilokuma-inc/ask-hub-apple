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
        for move in moves {
            guard let sha = try await treeSHA(of: move.from) else { continue }
            guard try await treeSHA(of: move.to) == nil, try await read(move.to) == nil else { throw .conflict }
            for file in try await tree(sha: sha, under: move.from, recursive: true) {
                entries.append(MoveTreeEntry(path: file.path, sha: nil))
                entries.append(MoveTreeEntry(path: move.to + file.path.dropFirst(move.from.count), sha: file.sha))
            }
        }
        guard !entries.isEmpty else { return }
        let treeBody = TreeBody(baseTree: base, tree: entries)
        let tree = try await decode(ShaPayload.self, from: try await request("POST", "git/trees", body: treeBody))
        let commitBody = CommitBody(message: message, tree: tree.sha, parents: [head])
        let commit = try await decode(ShaPayload.self, from: try await request("POST", "git/commits", body: commitBody))
        do {
            _ = try await request("PATCH", "git/refs/heads/\(branch)", body: RefBody(sha: commit.sha, force: false))
        } catch .unexpected(status: 422, _) {
            // 早送りにならない（読んだ後にほかの書き手が書いた）
            throw .conflict
        }
    }

    /// 書き込むブランチ。決めていなければ、リポジトリの既定のブランチ
    private func branchName() async throws(StateStoreError) -> String {
        if let branch { return branch }
        let name = try await decode(RepositoryPayload.self, from: try await request("GET", nil)).defaultBranch
        // ブランチの名前は URL のパスに入れるので、形を確かめる
        guard !name.isEmpty, !name.hasPrefix("-"), name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-/".contains($0)) }),
              !name.contains("..") else {
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
