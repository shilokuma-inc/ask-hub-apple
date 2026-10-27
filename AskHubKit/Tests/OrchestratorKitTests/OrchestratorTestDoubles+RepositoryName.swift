@testable import OrchestratorKit

// FakeGitHub の、担当リポジトリの今の名前（Issue #757）

struct FakeRepositoryNameState {
    /// 移管・改名の後の名前（キーは旧名の小文字）。無ければ渡された名前のまま
    var renamed: [String: String] = [:]
    var fails = false
    /// 今の名前を問い合わせたリポジトリ（呼ばれた順）
    var checked: [String] = []
}

extension FakeGitHub {
    func setRenamed(_ repository: String, to newName: String) {
        state.withLock { $0.repositoryNames.renamed[repository.lowercased()] = newName }
    }

    func setCurrentNameFails(_ fails: Bool) {
        state.withLock { $0.repositoryNames.fails = fails }
    }

    var checkedNames: [String] {
        state.withLock { $0.repositoryNames.checked }
    }

    func currentName(of repository: String) async throws -> String {
        try state.withLock { state in
            state.repositoryNames.checked.append(repository)
            if state.repositoryNames.fails {
                throw TestError()
            }
            return state.repositoryNames.renamed[repository.lowercased()] ?? repository
        }
    }
}
