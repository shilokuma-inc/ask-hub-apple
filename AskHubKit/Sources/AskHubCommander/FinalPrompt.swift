import Foundation

/// 最終 PR の Claude への依頼の文を、引数の大きさの上限に収める
enum FinalPrompt {
    /// 変わったファイルの一覧と差分
    static func changes(stat: String, diff: String) -> String {
        "\(stat)\n\n\(diff.isBlank ? "（差分なし）" : diff)"
    }

    /// `text` に差分を入れた依頼の文を、`budget` バイト（UTF-8）に収める。区切りのタグの中の `<` を `&lt;` にすると大きくなるので、
    /// 組み立てた後に測り、超えた分だけ差分を詰め直す。差分の外だけで超える・差分を少しも渡せないときは nil
    static func fitted(_ changes: String, budget: Int, text: (String) -> String) -> String? {
        var room = budget - text("").utf8.count
        guard room >= 0 else { return nil }
        var fitted = TaskReview.fit(changes, bytes: room)
        var prompt = text(fitted)
        // 残りが 0 になれば差分は空で、差分の外だけの大きさ（上限以内と確かめた）になるので、必ず止まる
        while prompt.utf8.count > budget {
            room = max(room - (prompt.utf8.count - budget), 0)
            fitted = TaskReview.fit(changes, bytes: room)
            prompt = text(fitted)
        }
        return fitted.isEmpty ? nil : prompt
    }
}
