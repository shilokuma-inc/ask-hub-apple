import Foundation

/// 「進行中」に並べるリリース。終わっていない審査（AskHub で始めたリリース・App Store Connect で出した版）と、後作業が終わっていない配信した版
enum ReleaseProgress: Identifiable, Hashable {
    case submission(Submission)
    case release(Release)

    var id: String {
        switch self {
        case .submission(let submission): "submission/\(submission.repositoryID)/\(submission.version)"
        case .release(let release): "release/\(release.id)"
        }
    }

    var repositoryID: TargetRepository.ID {
        switch self {
        case .submission(let submission): submission.repositoryID
        case .release(let release): release.repositoryID
        }
    }

    var version: String {
        switch self {
        case .submission(let submission): submission.version
        case .release(let release): release.version
        }
    }

    var route: AppRoute {
        switch self {
        case .submission(let submission): .submission(repositoryID: submission.repositoryID, version: submission.version)
        case .release(let release): .release(repositoryID: release.repositoryID, version: release.version)
        }
    }

    /// 反映を待つ操作の対象（行の小さな印）
    var target: IntentTarget {
        switch self {
        case .submission(let submission): .submission(repositoryID: submission.repositoryID, version: submission.version)
        case .release(let release): .release(repositoryID: release.repositoryID, version: release.version)
        }
    }

    /// 版の横に添える種類
    var kindLabel: String {
        switch self {
        case .submission(let submission): submission.startedInAskHub ? "リリース中" : "審査に出した版"
        case .release: "配信の後作業"
        }
    }

    /// 今の段取りの一言
    var summary: String {
        switch self {
        case .submission(let submission): submission.summary
        case .release(let release): release.needsHuman ? "人が直す後作業があります" : "司令塔が後作業を進めています"
        }
    }

    /// 人が直すまで進まない
    var needsHuman: Bool {
        switch self {
        case .submission(let submission): submission.needsHuman || submission.isRejected
        case .release(let release): release.needsHuman
        }
    }

    /// 進めているリリースを、新しい順（審査の後に後作業）に並べる。対象から外したリポジトリのものは出さない
    static func items(in snapshot: ClientSnapshot) -> [ReleaseProgress] {
        let submissions = snapshot.submissions.filter { !$0.isEnded && !snapshot.isRemoved($0.repositoryID) }
        let releases = snapshot.releases.filter { !$0.isFinished && !snapshot.isRemoved($0.repositoryID) }
        return submissions.map(Self.submission) + releases.sorted { $0.updatedAt > $1.updatedAt }.map(Self.release)
    }
}
