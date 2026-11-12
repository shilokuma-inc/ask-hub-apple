/// 司令塔とワーカーの間の決まりの互換の番号（`docs/renewal/operations.md` の「版」）。生きている印の `versions.compatibility` に書く。
///
/// 版の一致ではなく、この番号で照らし合わせる（共同開発者のワーカーは、司令塔を入れ替えるたびにそろえられないため）。
/// 司令塔とワーカーの間の決まり（ジョブの種類・入力と出力・試行の書き方・状態のファイルの形）を変えたときだけ上げる
public enum MachineCompatibility {
    public static let current = 1
}
