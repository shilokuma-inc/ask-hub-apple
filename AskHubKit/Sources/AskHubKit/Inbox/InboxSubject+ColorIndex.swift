import Foundation

extension InboxSubject {
    /// 要回答の一覧で、Discussion ごとに付ける色のパレットの添字（Discussion #418 の Q1）。PR の ask には色を付けないので `nil`（Q2）。
    ///
    /// node id の文字列だけから決まる計算（FNV-1a）で求めるので、取り直しても起動し直しても同じ Discussion は同じ色になる。
    /// `hashValue` / `Hasher` はプロセスごとに値が変わるので使わない
    public func colorIndex(paletteCount: Int) -> Int? {
        guard kind == .discussion, paletteCount > 0 else {
            return nil
        }
        return Int(Self.fnv1a(nodeID) % UInt64(paletteCount))
    }

    /// 64 ビットの FNV-1a（UTF-8 のバイト列）
    static func fnv1a(_ string: String) -> UInt64 {
        string.utf8.reduce(0xcbf2_9ce4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01b3 }
    }
}
