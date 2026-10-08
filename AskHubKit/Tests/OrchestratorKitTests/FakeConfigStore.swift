import Foundation
@testable import OrchestratorKit
import os

/// 設定の読み直しと担当リポジトリの書き換えの差し替え。書き換えた担当リポジトリで設定を返す
final class FakeConfigStore: OrchestratorConfigStore {
    struct State {
        var config: OrchestratorConfig
        var added: [String] = []
        var removed: [String] = []
        var loadFails = false
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

    func setLoadFails(_ fails: Bool) {
        state.withLock { $0.loadFails = fails }
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
            repositoryCommands: repositoryCommands,
            trustsRepositoryWriters: trustsRepositoryWriters
        )
    }
}
