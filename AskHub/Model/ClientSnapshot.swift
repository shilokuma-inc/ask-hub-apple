import Foundation

/// 1 回の取得で読んだ状態の全体。画面はすべてここから組み立てる
struct ClientSnapshot: Hashable {
    var repositories: [TargetRepository]
    /// まだ対象になっていないリポジトリ（「対象に加える」で選ぶ候補）
    var candidateRepositories: [TargetRepository]
    var epics: [Epic]
    var macs: [Mac]
    var fetchedAt: Date
    /// 一部の取得元だけ読めなかったとき。空なら全部読めた
    var sourceFailures: [SourceFailure]
}

/// 読めなかった取得元。「取得に失敗した」と「0 件」を分けて出すために持つ
struct SourceFailure: Hashable {
    /// 例: 状態リポジトリ
    var source: String
    var message: String
}

extension ClientSnapshot {
    func repository(_ id: TargetRepository.ID) -> TargetRepository? {
        repositories.first { $0.id == id }
    }

    func epic(_ id: Epic.ID) -> Epic? {
        epics.first { $0.id == id }
    }

    func mac(_ id: Mac.ID?) -> Mac? {
        guard let id else {
            return nil
        }
        return macs.first { $0.id == id }
    }

    var activeEpics: [Epic] {
        epics.filter(\.isActive)
    }

    /// そのリポジトリを回してよい Mac
    func allowedMacs(for repositoryID: TargetRepository.ID) -> [Mac] {
        guard let repository = repository(repositoryID) else {
            return []
        }
        return macs.filter { repository.allowedMacIDs.contains($0.id) }
    }
}
