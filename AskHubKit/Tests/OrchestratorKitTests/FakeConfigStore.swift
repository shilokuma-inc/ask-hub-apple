import Foundation
@testable import OrchestratorKit
import os

/// 設定の読み直しと担当リポジトリの書き換えの差し替え。書き換えた担当リポジトリで設定を返す
final class FakeConfigStore: OrchestratorConfigStore {
    struct State {
        var config: OrchestratorConfig
        var added: [String] = []
        var removed: [String] = []
        var renamed: [String] = []
        var loadFails = false
        var renameFails = false
    }

    let state: OSAllocatedUnfairLock<State>

    init(_ config: OrchestratorConfig) {
        state = OSAllocatedUnfairLock(initialState: State(config: config))
    }

    var added: [String] {
        state.withLock { $0.added }
    }

    var removed: [String] {
        state.withLock { $0.removed }
    }

    var renamed: [String] {
        state.withLock { $0.renamed }
    }

    func setLoadFails(_ fails: Bool) {
        state.withLock { $0.loadFails = fails }
    }

    func setRenameFails(_ fails: Bool) {
        state.withLock { $0.renameFails = fails }
    }

    func load() throws -> OrchestratorConfig {
        try state.withLock { state in
            if state.loadFails {
                throw OrchestratorConfigError.invalidJSON(reason: "書きかけ")
            }
            return state.config
        }
    }

    func addRepository(_ fullName: String, checkoutPath: String) throws {
        state.withLock { state in
            state.added.append("\(fullName) \(checkoutPath)")
            let parts = fullName.split(separator: "/").map(String.init)
            state.config = state.config.replacingRepositories(
                state.config.repositories + [RepositoryConfig(owner: parts[0], name: parts[1], checkoutPath: checkoutPath)]
            )
        }
    }

    func removeRepository(_ fullName: String) throws {
        state.withLock { state in
            state.removed.append(fullName)
            state.config = state.config.replacingRepositories(
                state.config.repositories.filter { $0.fullName.caseInsensitiveCompare(fullName) != .orderedSame }
            )
        }
    }

    func renameRepository(_ fullName: String, to newName: String) throws {
        try state.withLock { state in
            if state.renameFails {
                throw OrchestratorConfigError.invalidJSON(reason: "書き込めない")
            }
            state.renamed.append("\(fullName) → \(newName)")
            let parts = newName.split(separator: "/").map(String.init)
            state.config = state.config.replacingRepositories(
                state.config.repositories.map { repository in
                    guard repository.fullName.caseInsensitiveCompare(fullName) == .orderedSame else {
                        return repository
                    }
                    return RepositoryConfig(owner: parts[0], name: parts[1], checkoutPath: repository.checkoutPath)
                }
            )
        }
    }
}

extension OrchestratorConfig {
    func replacingRepositories(_ repositories: [RepositoryConfig]) -> Self {
        Self(
            trustedAuthorLogins: trustedAuthorLogins,
            repositories: repositories,
            pollInterval: pollInterval,
            loopCommand: loopCommand,
            ideaCommand: ideaCommand,
            iterationTimeout: iterationTimeout,
            conflictCommand: conflictCommand,
            reviewCommand: reviewCommand,
            fixCommand: fixCommand,
            ciFixCommand: ciFixCommand,
            repositoryCommands: repositoryCommands,
            trustsRepositoryWriters: trustsRepositoryWriters
        )
    }
}
