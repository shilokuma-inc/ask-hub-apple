import AskHubProtocol
import Foundation

/// 「対象に加える」の候補（司令塔が書いた `repo-candidates.json`）
extension StateSnapshotBuilder {
    /// 「対象に加える」の候補のうち、まだ対象でないもの（対象・外したリポジトリと、加えると送ったものを除く）
    func candidates(excluding known: [TargetRepository], index: inout StateIndex) -> [RepositoryCandidate] {
        let excluded = Set(known.map(\.id))
        var candidates: [RepositoryCandidate] = []
        for owner in documents.repositoryCandidates?.owners ?? [] {
            for repository in owner.repositories {
                guard let repo = owner.fullName(of: repository) else { continue }
                let candidate = RepositoryCandidate(
                    owner: repo.owner,
                    name: repo.name,
                    isPrivate: repository.isPrivate,
                    description: repository.description,
                    pushedAt: repository.pushedAt?.date
                )
                guard !excluded.contains(candidate.id), index.candidateRepositories[candidate.id] == nil else { continue }
                index.candidateRepositories[candidate.id] = repo
                candidates.append(candidate)
            }
        }
        return candidates.sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    /// 候補を読めなかった持ち主
    var candidateProblems: [RepositoryCandidateProblem] {
        (documents.repositoryCandidates?.owners ?? []).compactMap { owner in
            owner.problem.map { RepositoryCandidateProblem(owner: owner.owner, message: $0) }
        }
    }
}
