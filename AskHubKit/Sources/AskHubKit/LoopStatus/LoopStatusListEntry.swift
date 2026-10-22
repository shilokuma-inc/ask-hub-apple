import Foundation

/// ステータスタブのリポジトリの節の中の 1 行（`List` の 1 行）。
///
/// 1 つのリポジトリから、ループが 1 つ以下なら 1 行、2 つ以上なら「見出し + ループごとの行」が出る。リポジトリ 1 つを `ForEach` の 1 要素にすると、
/// ループの数が変わったときに 1 要素から出る行の数が更新の前後で変わり、`List`（iOS では `UICollectionView`）が差分を当てるときに落ちることがある。
/// そのため、行をすべてこの型に並べてから 1 つの `ForEach` で出す（1 要素 = 常に 1 行）
public struct LoopStatusListEntry: Sendable, Equatable, Identifiable {
    /// 行の種類
    public enum Kind: Sendable, Equatable {
        /// ループが 1 つ以下のリポジトリ（今までどおり 1 行で出す）
        case repository(LoopStatusRow)
        /// ループが 2 つ以上のリポジトリの見出し。`loopCount` は見出しの下に並べるループの数
        case heading(LoopStatusRow, loopCount: Int)
        /// 見出しの下に並べるループ 1 つ
        case loop(LoopStatusLoopItem)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    /// 種類ごとの接頭辞を付けて、同じリポジトリの 1 行・見出し・ループの行が重ならないようにする（`repository:owner/repo`・`heading:owner/repo`・`loop:owner/repo#12`。小文字）
    public var id: String {
        switch kind {
        case let .repository(row): "repository:\(row.id)"
        case let .heading(row, _): "heading:\(row.id)"
        case let .loop(item): "loop:\(item.id)"
        }
    }

    /// リポジトリの行を、節の中の行の並びにする（リポジトリの順のまま、ループが 2 つ以上なら見出しの直後にループを並べる）
    /// - Parameter manualLoops: 開いている手動ループ（ループの行の担当者を出すのに使う）
    public static func entries(of rows: [LoopStatusRow], manualLoops: [ManualLoopEpic]) -> [Self] {
        let entries = rows.flatMap { row -> [Self] in
            let items = row.loopItems(manualLoops: manualLoops)
            guard !items.isEmpty else {
                return [Self(kind: .repository(row))]
            }
            return [Self(kind: .heading(row, loopCount: items.count))] + items.map { Self(kind: .loop($0)) }
        }
        // 行もループも取得の段階で重なりを除いているが、1 つの `ForEach` に出すので念のため id でも除く
        return entries.uniqued(by: \.id)
    }
}
