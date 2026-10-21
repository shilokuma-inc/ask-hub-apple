@testable import OrchestratorKit

// FakeGitHub の、依頼先のリポジトリの Discussions の設定（Issue #719）

struct FakeDiscussionSettingsState {
    /// キーはリポジトリ。無ければ有効でカテゴリ「Ideas」がある
    var settings: [String: DiscussionSettings] = [:]
    var settingsFails = false
    /// Discussions を有効にしたリポジトリ（呼ばれた順）
    var enabled: [String] = []
    var enableFails = false
}

extension FakeGitHub {
    func setDiscussionSettings(_ settings: DiscussionSettings, in repository: String) {
        state.withLock { $0.discussions.settings[repository] = settings }
    }

    func setDiscussionSettingsFails(_ fails: Bool) {
        state.withLock { $0.discussions.settingsFails = fails }
    }

    func setEnableDiscussionsFails(_ fails: Bool) {
        state.withLock { $0.discussions.enableFails = fails }
    }

    var enabledDiscussions: [String] {
        state.withLock { $0.discussions.enabled }
    }

    func discussionSettings(in repository: String) async throws -> DiscussionSettings {
        try state.withLock { state in
            if state.discussions.settingsFails {
                throw TestError()
            }
            return state.discussions.settings[repository] ?? DiscussionSettings(isEnabled: true, categories: ["General", "Ideas"])
        }
    }

    /// 有効にすると、GitHub と同じく既定のカテゴリを持つ
    func enableDiscussions(in repository: String) async throws {
        try state.withLock { state in
            if state.discussions.enableFails {
                throw TestError()
            }
            state.discussions.enabled.append(repository)
            state.discussions.settings[repository] = DiscussionSettings(isEnabled: true, categories: ["General", "Ideas"])
        }
    }
}
