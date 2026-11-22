import AskHubProtocol
import AskHubStateStore
import Foundation

extension StateReader {
    /// リポジトリの App Store に載せる準備の記録。中身のリポジトリが置き場所と合うものだけ出す
    func appStoreSetup(of repo: RepositoryFullName) async -> Part<AppStoreSetupFile?> {
        let read = await read(AppStoreSetupFile.self, at: StatePath.appStoreSetup(repo))
        return Part(value: read.value.flatMap { $0.repo == repo ? $0 : nil }, failures: read.failures)
    }

    /// リポジトリのクリエイティブアセットの案と反映。中身のリポジトリが置き場所と合うものだけ出す
    func creative(of repo: RepositoryFullName) async -> Part<CreativeFile?> {
        let read = await read(CreativeFile.self, at: StatePath.creative(repo))
        return Part(value: read.value.flatMap { $0.repo == repo ? $0 : nil }, failures: read.failures)
    }
}
