import Foundation
@testable import OrchestratorKit

// FakeGitHub の、GitHub から集める最終 PR の材料
extension FakeGitHub {
    func setEpicMaterials(_ materials: EpicMaterials, for branch: String) {
        state.withLock { $0.epicMaterials[branch] = materials }
    }

    func epicMaterials(in repository: String, branch: String) async throws -> EpicMaterials {
        let empty = EpicMaterials(mergedPullRequests: [], openPullRequests: [], decisionLogs: [], verifyIssues: [])
        return state.withLock { $0.epicMaterials[branch] } ?? empty
    }
}
