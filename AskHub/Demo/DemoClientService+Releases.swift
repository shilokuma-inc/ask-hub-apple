import Foundation

// MARK: - 人の意図を当てる（配信した版）

extension DemoClientService {
    /// リリース文の公開。司令塔が受け付けて本文を記録に写し、次の見回りで GitHub Release を公開するのをまねる
    func applyReleaseIntent(_ intent: HumanIntent) {
        guard case let .publishRelease(repositoryID, version, _, notes) = intent else {
            return
        }
        let id = Release.id(repositoryID, version)
        state.updateRelease(id) { $0.publish = .sending }
        schedule { snapshot in
            snapshot.updateRelease(id) { release in
                release.publish = .none
                release.notes?.confirmed = notes
            }
        }
        schedule(after: 2) { snapshot in
            snapshot.updateRelease(id) { release in
                release.githubReleaseURL = URL(string: "https://github.com/\(repositoryID)/releases/tag/v\(version)")
            }
        }
    }
}

extension ClientSnapshot {
    mutating func updateRelease(_ id: Release.ID, _ change: (inout Release) -> Void) {
        guard let index = releases.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&releases[index])
    }
}
