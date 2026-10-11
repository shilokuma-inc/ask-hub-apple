import Foundation

extension LoopStatusBuilds {
    /// ステータスタブの行に出すビルドの行（スロットごとに 1 行）。実行中のビルドがあればそれを、無ければ直近に終わったビルドを出す。
    /// 移動や失敗はバッジ（異常の件数）には数えない（Discussion #366 の Q7。表示だけ）
    public var rowTexts: [String] {
        // 同じスロットで並べて流したビルドは、最も新しく始まったものだけを出す
        let running = Dictionary(grouping: running, by: \.slot).values.compactMap { builds in
            builds.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        }
        let runningSlots = Set(running.map(\.slot))
        let finished = latest.filter { !runningSlots.contains($0.slot) }
        return (running + finished)
            .sorted { $0.slot < $1.slot }
            .map(\.rowText)
    }
}

extension LoopStatusBuild {
    /// 「ビルド中 a: macbookpro-m4max（2 回目・macbookpro-m1pro から移動）」
    /// 「直近のテスト b: 失敗・macbookpro-m1pro（1 回目）」
    public var rowText: String {
        var details: [String] = []
        if let attempt {
            details.append("\(attempt) 回目")
        }
        if let move = moves.last {
            var text = "\(move.from) から移動"
            if moves.count > 1 {
                text += "・移動 \(moves.count) 回"
            }
            details.append(text)
        }
        let detailText = details.isEmpty ? "" : "（\(details.joined(separator: "・"))）"
        guard isFinished else {
            // 移動した直後・Mac の空き待ちのあいだは、まだ Mac が決まっていない
            let place = host ?? "Mac の空き待ち"
            return "\(actionTitle)中 \(slot): \(place)\(detailText)"
        }
        let place = host.map { "・\($0)" } ?? ""
        return "直近の\(actionTitle) \(slot): \(resultText)\(place)\(detailText)"
    }

    /// xcb の `action` の日本語。知らないものはそのまま
    var actionTitle: String {
        Self.actionTitle(of: action)
    }
}
