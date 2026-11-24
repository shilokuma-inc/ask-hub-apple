import Foundation

/// 実機確認の残り。マージした epic のうち、まだ答えていない（確かめられる）項目があるものを、確かめるものと
/// 配信した版の確認（畳んだもの）に分ける（`docs/renewal/flows.md` の「実機で確かめてほしいこと」の「溜まった確認を減らす」）
struct VerificationBacklog: Hashable {
    /// 1 つの epic の残り
    struct Entry: Identifiable, Hashable {
        var epic: Epic
        /// まだ答えていない、確かめられる項目
        var items: [VerificationItem]
        /// 最終 PR をマージした時刻。分からなければ nil
        var mergedAt: Date?
        /// 畳んだわけの、配信した版。畳んでいなければ nil
        var foldedBy: Release?

        var id: Epic.ID { epic.id }

        /// 一覧の行で働きかける対象（まとめての答えと、項目ごとの答え）
        var targets: [IntentTarget] {
            [.verifications(epicID: epic.id)] + items.map { .verification(epicID: epic.id, itemID: $0.id) }
        }
    }

    /// 確かめるもの（新しくマージした順）
    var open: [Entry]
    /// 配信した版の確認（畳んだもの。新しくマージした順）。あなたの番に数えず、まとめてスワイプする山札にも入れない
    var folded: [Entry]
}

extension VerificationBacklog {
    init(snapshot: ClientSnapshot) {
        let entries = snapshot.epics.compactMap { epic -> Entry? in
            let items = epic.finalReview?.verifications.filter(\.isReady) ?? []
            guard !items.isEmpty else {
                return nil
            }
            let mergedAt = epic.finalReview?.mergedAt
            let release = VerificationFold.foldingRelease(
                mergedAt: mergedAt,
                repositoryID: epic.repositoryID,
                releases: snapshot.releases,
                submissions: snapshot.submissions
            )
            return Entry(epic: epic, items: items, mergedAt: mergedAt, foldedBy: release)
        }
        .sorted { ($0.mergedAt ?? $0.epic.updatedAt) > ($1.mergedAt ?? $1.epic.updatedAt) }
        self.init(open: entries.filter { $0.foldedBy == nil }, folded: entries.filter { $0.foldedBy != nil })
    }

    /// 確かめるものの項目の数
    var openItemCount: Int {
        open.reduce(0) { $0 + $1.items.count }
    }

    var isEmpty: Bool {
        open.isEmpty && folded.isEmpty
    }
}

/// 実機確認を畳む規則。次の版を配信したら、前の版の確認は自動で畳む（ユーザーの決定。2026-11-24）。
/// 状態リポジトリには何も書かず、配信の記録（`releases/<版>.json`）とリリースを始めた版の記録からクライアントが決める
enum VerificationFold {
    /// 版を切った時刻。release ブランチを作った時刻（リリースを始めた版の記録）、分からなければその版のビルドを上げた最も早い時刻、
    /// それも分からなければ司令塔が配信を見つけた時刻
    static func cutAt(of release: Release, submissions: [Submission]) -> Date {
        let submission = submissions.first { $0.repositoryID == release.repositoryID && $0.version == release.version }
        return submission?.branchCreatedAt ?? release.platforms.compactMap(\.uploadedAt).min() ?? release.detectedAt
    }

    /// epic の残りの確認を畳む、配信した版。そのリポジトリで、epic をマージした時刻と同じか後に切った版のうち、最も早く切ったもの。
    /// 畳まない（マージした時刻が分からない・そういう版が無い）なら nil
    static func foldingRelease(
        mergedAt: Date?,
        repositoryID: TargetRepository.ID,
        releases: [Release],
        submissions: [Submission]
    ) -> Release? {
        guard let mergedAt else {
            return nil
        }
        return releases
            .filter { $0.repositoryID == repositoryID }
            .map { (release: $0, cutAt: cutAt(of: $0, submissions: submissions)) }
            .filter { $0.cutAt >= mergedAt }
            .min { $0.cutAt < $1.cutAt }?
            .release
    }
}
