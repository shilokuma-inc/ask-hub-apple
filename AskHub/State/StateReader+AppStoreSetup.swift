import AskHubProtocol
import AskHubStateStore
import Foundation

extension StateReader {
    /// リポジトリの App Store に載せる準備の記録。中身のリポジトリが置き場所と合うものだけ出す
    func appStoreSetup(of repo: RepositoryFullName) async -> Part<AppStoreSetupFile?> {
        let read = await read(AppStoreSetupFile.self, at: StatePath.appStoreSetup(repo))
        return Part(value: read.value.flatMap { $0.repo == repo ? $0 : nil }, failures: read.failures)
    }
}
