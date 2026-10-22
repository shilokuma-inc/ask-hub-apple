import Foundation

extension Sequence {
    /// `key` が同じ要素は、先に出たものだけを残す（並びは変えない）。
    ///
    /// SwiftUI の `List` は、同じ `ForEach` に同じ id の要素が 2 つ以上あると、差分を当てるときに `UICollectionView` の整合性の検証で落ちることがある。
    /// GitHub の search をページングでたどると、取得の途中で順位が動いて同じ要素が 2 ページに出ることがあるので、一覧に出す取得の結果はこれで除く
    public func uniqued<Key: Hashable>(by key: (Element) throws -> Key) rethrows -> [Element] {
        var seen: Set<Key> = []
        var result: [Element] = []
        for element in self where seen.insert(try key(element)).inserted {
            result.append(element)
        }
        return result
    }
}
