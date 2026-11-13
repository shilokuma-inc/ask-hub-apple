import AskHubProtocol
import Foundation

// MARK: - App Store で配信した版

extension StateSnapshotBuilder {
    /// 配信した版（リポジトリの順、その中は新しい版から）。この端末が送って司令塔がまだ処理していない公開は、送った結果として先に出し、
    /// 断られた公開は、その下書きのままなら理由を出す
    func releases(index: inout StateIndex, overlaid: [IntentEnvelope]) -> [Release] {
        var releases: [Release] = []
        let files = documents.releases.sorted { lhs, rhs in
            lhs.repo.rawValue.lowercased() == rhs.repo.rawValue.lowercased() ? lhs.version > rhs.version
                : lhs.repo.rawValue.localizedStandardCompare(rhs.repo.rawValue) == .orderedAscending
        }
        for file in files {
            var release = Self.release(file)
            let canPublish = file.awaitsNotesReview
            if let notes = file.notes {
                let target = ReleaseTarget(repo: file.repo, version: file.version, notesVersion: notes.version)
                index.releases[release.id] = StateIndex.ReleaseEntry(target: target, canPublish: canPublish)
            }
            if canPublish, let notes = file.notes {
                if overlaid.contains(where: { Self.publishes($0, file: file, notesVersion: notes.version) }) {
                    release.publish = .sending
                    index.releases[release.id]?.canPublish = false
                } else if let reason = rejectedPublish(of: file, notesVersion: notes.version) {
                    release.publish = .rejected(reason)
                }
            }
            releases.append(release)
        }
        return releases
    }

    static func release(_ file: ReleaseFile) -> Release {
        Release(
            repositoryID: repository(file.repo).id,
            version: file.version.rawValue,
            platforms: file.platforms.map { Release.Platform(name: $0.platform.rawValue, build: $0.build) },
            detectedAt: file.detectedAt.date,
            updatedAt: file.updatedAt.date,
            commit: file.commit.map { Release.Commit(sha: $0.sha, fromExistingTag: $0.source == .existingTag) },
            tagName: file.tag?.name,
            notes: file.notes.map { notes in
                Release.Notes(
                    version: notes.version, previousTag: notes.previousTag, draft: notes.draft, confirmed: notes.confirmed?.text
                )
            },
            githubReleaseURL: file.githubRelease.flatMap { URL(string: $0.url) },
            nextVersion: file.nextVersion.map { next in
                Release.NextVersion(version: next.version.rawValue, state: Self.nextVersionState(next.state), pullRequest: next.pullRequest)
            },
            problem: file.problem.map { problem in
                Release.Problem(
                    step: Self.step(problem.step), message: problem.message, needsHuman: problem.needsHuman, at: problem.at.date
                )
            }
        )
    }

    /// その版の、その下書きへの公開の意図か
    private static func publishes(_ envelope: IntentEnvelope, file: ReleaseFile, notesVersion: Int) -> Bool {
        guard envelope.kind == PublishGitHubReleaseIntent.kind, let intent = try? PublishGitHubReleaseIntent(envelope: envelope) else {
            return false
        }
        return intent.target.repo.rawValue.lowercased() == file.repo.rawValue.lowercased() && intent.target.version == file.version
            && intent.target.notesVersion == notesVersion
    }

    /// 今の下書きへの公開を、司令塔が最後に断った理由。断られていなければ（後で受け付けた・送っていない）nil
    private func rejectedPublish(of file: ReleaseFile, notesVersion: Int) -> String? {
        let latest = documents.sentIntents.first { Self.publishes($0.envelope, file: file, notesVersion: notesVersion) }
        guard let consumed = latest?.consumed, consumed.result == .rejected else {
            return nil
        }
        return consumed.reason ?? "理由は書かれていません"
    }

    private static func nextVersionState(_ state: ReleaseFile.NextVersionState) -> Release.NextVersionState {
        switch state {
        case .open: .open
        case .merged: .merged
        case .skipped: .skipped
        }
    }

    private static func step(_ step: ReleaseFile.Step) -> Release.Step {
        switch step {
        case .commit: .commit
        case .tag: .tag
        case .notes: .notes
        case .githubRelease: .githubRelease
        case .nextVersion: .nextVersion
        }
    }
}
