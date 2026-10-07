/// 検索クエリで対象の organization を絞る修飾子。
///
/// `org:` を並べると OR で検索されるので、organization がいくつあっても検索は 1 回で済む（Search API は 30 回/分のため）
public enum SearchScope {
    /// `org:a org:b`。organization が無ければ `nil`（修飾子なしで GitHub 全体を検索しないため）
    public static func organizations(_ orgs: [String]) -> String? {
        guard !orgs.isEmpty else {
            return nil
        }
        return orgs.map { "org:\($0)" }.joined(separator: " ")
    }
}
