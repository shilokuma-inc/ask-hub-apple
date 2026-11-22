import Foundation

/// 「対象に加える」の候補。司令塔が毎日のトークンで持ち主ごとに読んだリポジトリ（`repo-candidates.json`）のうち、まだ対象でないもの
struct RepositoryCandidate: Identifiable, Hashable {
    /// `owner/name` を小文字にしたもの（対象のリポジトリの id と同じ形）
    var id: String { fullName.lowercased() }
    let owner: String
    let name: String
    var isPrivate = false
    var description: String?
    var pushedAt: Date?

    var fullName: String { "\(owner)/\(name)" }

    /// 名前か説明に `query` を含むか（空なら全部）
    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || fullName.localizedCaseInsensitiveContains(query)
            || (description?.localizedCaseInsensitiveContains(query) ?? false)
    }
}

/// 候補を読めなかった持ち主（司令塔が書いた理由）
struct RepositoryCandidateProblem: Hashable {
    let owner: String
    let message: String
}
