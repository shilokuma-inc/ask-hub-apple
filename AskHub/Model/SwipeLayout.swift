import CoreGraphics

/// カードをスワイプする方向。すべて斜め（ユーザーの決定。2026-11-03）
enum SwipeDirection: Hashable, CaseIterable {
    case upRight
    case upLeft
    case downLeft
    case downRight

    /// 画面の座標（y は下が正）での向きの単位ベクトル
    var unit: CGVector {
        let component = 1 / 2.0.squareRoot()
        switch self {
        case .upRight: return CGVector(dx: component, dy: -component)
        case .upLeft: return CGVector(dx: -component, dy: -component)
        case .downLeft: return CGVector(dx: -component, dy: component)
        case .downRight: return CGVector(dx: component, dy: component)
        }
    }

    var mirrored: Self {
        switch self {
        case .upRight: .upLeft
        case .upLeft: .upRight
        case .downLeft: .downRight
        case .downRight: .downLeft
        }
    }

    /// 対角の方向（↗ なら ↙）
    var opposite: Self {
        switch self {
        case .upRight: .downLeft
        case .upLeft: .downRight
        case .downLeft: .upRight
        case .downRight: .upLeft
        }
    }

    var systemImage: String {
        switch self {
        case .upRight: "arrow.up.right"
        case .upLeft: "arrow.up.left"
        case .downLeft: "arrow.down.left"
        case .downRight: "arrow.down.right"
        }
    }

    var accessibilityName: String {
        switch self {
        case .upRight: "右上"
        case .upLeft: "左上"
        case .downLeft: "左下"
        case .downRight: "右下"
        }
    }
}

/// スマホを持つ手。設定で切り替える
enum Handedness: String, Hashable, CaseIterable {
    case right
    case left

    var label: String {
        switch self {
        case .right: "右手"
        case .left: "左手"
        }
    }
}

/// 選択肢と方向の割り当て、スワイプの判定
enum SwipeLayout {
    /// これ以上動かして離すと決まる距離（pt）
    static let commitDistance: CGFloat = 120
    /// これより短い動きは、どの方向にも数えない
    static let minimumDistance: CGFloat = 16

    /// 選択肢の数ごとの方向。先頭（推奨）はいつも利き手側の上（右手なら ↗）。
    /// 右手は 2 択 ↗↙・3 択 ↗↖↙（↘ を使わない）・4 択 ↗↖↙↘。左手は鏡写し。
    /// 自由回答を推奨の対角に置くのは、選択肢の並び（`arranged`）で決める
    static func directions(count: Int, hand: Handedness) -> [SwipeDirection] {
        let right: [SwipeDirection]
        switch count {
        case ...0:
            right = []

        case 1:
            right = [.upRight]

        case 2:
            right = [.upRight, .downLeft]

        case 3:
            right = [.upRight, .upLeft, .downLeft]

        default:
            right = [.upRight, .upLeft, .downLeft, .downRight]
        }
        return hand == .right ? right : right.map(\.mirrored)
    }

    /// 自由回答の選択肢（送る前に文を書くもの）を、推奨（先頭）の対角の位置へ並べ替える（ユーザーの決定。2026-11-04）。
    /// 右手なら ↗ の推奨と ↙ の自由回答が対になる。左手は鏡写しで、対角の位置の添字は変わらない。
    ///
    /// - 先頭は推奨の位置なので動かさない。先頭が自由回答でも推奨を優先して ↗ に残し、ほかに自由回答があれば、その 1 つ目を対角に置く
    /// - 対角に置くのは 1 つ目の自由回答だけ。2 つ目からは空いている方向のまま
    /// - 自由回答が無ければ、並びは変えない
    static func arranged<Item>(_ items: [Item], asksText: (Item) -> Bool) -> [Item] {
        let slots = directions(count: items.count, hand: .right)
        guard let first = slots.first,
              let pair = slots.firstIndex(of: first.opposite),
              let freeText = items.indices.dropFirst().first(where: { asksText(items[$0]) }),
              freeText != pair else {
            return items
        }
        // 抜いて差し込み、ほかの選択肢は書かれた順のままにする
        var result = items
        result.insert(result.remove(at: freeText), at: pair)
        return result
    }

    /// 動かした量から、どの選択肢に向かっているか（`directions` の添字）。どれにも向かっていなければ nil
    static func candidate(for translation: CGSize, directions: [SwipeDirection]) -> Int? {
        let distance = hypot(translation.width, translation.height)
        guard distance >= minimumDistance else {
            return nil
        }
        let threshold = cosineThreshold(directionCount: directions.count)
        var best: (index: Int, cosine: CGFloat)?
        for (index, direction) in directions.enumerated() {
            let cosine = (translation.width * direction.unit.dx + translation.height * direction.unit.dy) / distance
            if cosine > threshold, cosine > (best?.cosine ?? -1) {
                best = (index, cosine)
            }
        }
        return best?.index
    }

    /// 選択肢に向かっているとみなす、方向との角度の余弦の下限。
    /// 4 方向なら境目は縦横の軸。3 方向以下なら、使わない方向の近くでは選ばない
    static func cosineThreshold(directionCount: Int) -> CGFloat {
        directionCount >= 4 ? 0 : 0.5
    }

    /// 決まるまでの進み具合（0〜1）。色の濃さに使う
    static func progress(for translation: CGSize) -> Double {
        min(1, Double(hypot(translation.width, translation.height) / commitDistance))
    }

    /// 数字キー（1 から）で選ぶ選択肢の添字。選択肢の無い（自由記述の）カードや、数がはみ出したキーは nil
    static func choiceIndex(forKey characters: String, count: Int) -> Int? {
        guard let number = Int(characters), (0..<count).contains(number - 1) else {
            return nil
        }
        return number - 1
    }

    /// 離したときに決まるか。勢いよく弾いたとき（予測の位置が遠い）も決める
    static func commits(translation: CGSize, predictedEnd: CGSize) -> Bool {
        hypot(translation.width, translation.height) >= commitDistance
            || hypot(predictedEnd.width, predictedEnd.height) >= commitDistance * 2
    }
}
