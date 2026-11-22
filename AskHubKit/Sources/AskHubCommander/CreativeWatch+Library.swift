import AskHubProtocol
import AskHubStateStore
import Foundation

/// 承認したクリエイティブアセットを、App Store Connect のライブラリに上げておく（`docs/renewal/creative-assets.md` の「流れ」の 6）。
///
/// 人が案を承認すると（`approveCreativeAssets`）、見回りの周（5 分空ける）で、承認した画像を参照名 `askhub-<MD5>`・カテゴリ `CREATIVE_ASSETS` で
/// 上げる（配置はしない。ライブラリの画像は、配置して審査に出すまで App Store に出ない）。処理中（`UPLOAD_COMPLETE`）は消さずに待ち、予約だけで
/// 止まった画像は消して上げ直す。Apple が受け付けなかった画像には、画像の問題（`library-failed`）にわけを書く（人は案を作り直す）
extension CreativeWatch {
    /// ライブラリの画像の様子を読む間隔
    static let creativeLibraryCheckInterval: TimeInterval = 5 * 60
    /// ライブラリが受け付けなかった画像の問題の code
    static let libraryFailedCode = "library-failed"

    /// まだ置ける状態になっていない（受け付けられなかったものを除く）画像があるか
    static func awaitsLibrary(_ approved: CreativeFile.Approval) -> Bool {
        let checksums = Set(approved.images.map(\.md5))
        let failed = Set(approved.images.filter { $0.problems.contains { $0.code == libraryFailedCode } }.map(\.md5))
        guard let library = approved.library else { return true }
        return library.ready + failed.count < checksums.count
    }

    func advanceCreativeLibrary(_ file: CreativeFile, settings: RepositoryFile) async {
        guard let approved = file.approved, Self.awaitsLibrary(approved) else { return }
        let repo = file.repo
        let key = "\(repo.rawValue)/creative-library/\(approved.revision)"
        if let checked = checkedAt[key], context.now().timeIntervalSince(checked) < Self.creativeLibraryCheckInterval { return }
        checkedAt[key] = context.now()
        let outcome: LibraryOutcome
        do {
            outcome = try await uploadCreative(approved, repo: repo, base: Self.creativeBase(settings))
        } catch let problem as ReleaseStepProblem where problem.needsHuman {
            log("\(repo) の承認したクリエイティブアセットをライブラリに上げられない（\(problem.message)）")
            await updateCreativeFile(repo, message: "\(repo) のクリエイティブアセットをライブラリに上げられない") { file in
                let message = Self.clamp("承認した画像をライブラリに上げられない（\(problem.message)）", to: 1000)
                guard file.approved?.revision == approved.revision, file.problem != message else { return false }
                file.problem = message
                return true
            }
            return
        } catch {
            report("\(repo) の承認したクリエイティブアセットをライブラリに上げられない（\(error)）。次の見回りでやり直す")
            return
        }
        let now = context.timestamp
        let saved = await updateCreativeFile(repo, message: "\(repo) のクリエイティブアセットをライブラリに上げた") { file in
            Self.apply(outcome, to: &file, now: now)
        }
        if let library = saved?.approved?.library {
            log("\(repo) の承認したクリエイティブアセット（案 \(outcome.revision)）のライブラリの取り込み: \(library.ready) / \(library.total) 枚")
        }
    }

    /// 上げた結果を記録に写す（変わらなければ false）。受け付けられなかった画像には、使う言語のすべてにわけを書く
    static func apply(_ outcome: LibraryOutcome, to file: inout CreativeFile, now: Timestamp) -> Bool {
        guard var approved = file.approved, approved.revision == outcome.revision else { return false }
        let library = CreativeFile.Library(total: outcome.total, ready: outcome.ready, sentAt: approved.library?.sentAt ?? now)
        var images = approved.images
        for index in images.indices {
            guard let details = outcome.failures[images[index].md5],
                  !images[index].problems.contains(where: { $0.code == libraryFailedCode }) else { continue }
            let message = clamp("ライブラリが受け付けなかった（\(details)）", to: 500)
            images[index].problems.append(.init(code: libraryFailedCode, message: message))
        }
        guard library != approved.library || images != approved.images else { return false }
        approved.library = library
        approved.images = images
        file.approved = approved
        if file.problem?.hasPrefix("承認した画像をライブラリに上げられない") == true { file.problem = nil }
        return true
    }

    /// ライブラリに上げた結果
    struct LibraryOutcome: Sendable {
        var revision: Int
        /// 上げる画像の数（同じ画像は 1 つ）
        var total: Int
        /// 置ける状態になった数
        var ready: Int
        /// 受け付けられなかった画像（MD5 → わけ）
        var failures: [String: String]
    }

    /// 承認した画像を 1 つずつ確かめ、上げていなければ上げる
    private func uploadCreative(_ approved: CreativeFile.Approval, repo: RepositoryFullName, base: String) async throws -> LibraryOutcome {
        guard let root = originals else { throw ReleaseStepProblem("書き出した画像を置く場所が司令塔に無い", needsHuman: true) }
        guard let found = try await app(of: repo, base: base) else {
            throw ReleaseStepProblem("App Store Connect にアプリが無い", needsHuman: true)
        }
        let store = stores[found.store]
        let library = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.assetLibrary(of: found.app.id) }
        var checksums: [String] = []
        for image in approved.images where !checksums.contains(image.md5) { checksums.append(image.md5) }
        var outcome = LibraryOutcome(revision: approved.revision, total: checksums.count, ready: 0, failures: [:])
        let folder = root.appendingPathComponent("\(repo.owner)/\(repo.name)/\(approved.revision)", isDirectory: true)
        for checksum in checksums {
            guard let image = approved.images.first(where: { $0.md5 == checksum }) else { continue }
            let original = CreativeImport.original(in: folder, locale: image.locale, kind: image.kind)
            switch try await uploadOne(image, original: original, library: library, store: store) {
            case .ready: outcome.ready += 1
            case .processing: break
            case let .failed(details): outcome.failures[checksum] = details
            }
        }
        return outcome
    }

    /// ライブラリの 1 枚の画像の様子
    enum LibraryImageState: Sendable {
        case ready
        case processing
        case failed(String)
    }

    /// 1 枚の画像を確かめ、上げていなければ（予約だけで止まっていれば消して）上げる
    private func uploadOne(
        _ image: CreativeFile.Image,
        original: URL,
        library: String,
        store: any AppStoreConnecting
    ) async throws -> LibraryImageState {
        let reference = AppStoreScreenshot.referenceName(checksum: image.md5)
        let images = try await appStoreConnect { () throws(AppStoreConnectError) in
            try await store.libraryImages(in: library, referenceName: reference)
        }
        if images.contains(where: \.isPlaceable) { return .ready }
        if images.contains(where: \.isProcessing) { return .processing }
        if let failed = images.first(where: \.isFailed) { return .failed(failed.details ?? "わけは書かれていない") }
        for stale in images {
            try await appStoreConnect { () throws(AppStoreConnectError) in try await store.deleteImage(stale.id) }
        }
        guard let data = try? Data(contentsOf: original), CreativeImport.md5(data) == image.md5 else {
            throw ReleaseStepProblem("承認した画像（\(image.locale) の \(image.kind.rawValue)）が常時オンの Mac に無い。案を作り直す", needsHuman: true)
        }
        let fileName = "\(image.kind.fileName.dropLast(4))-\(image.locale).png"
        let id = try await appStoreConnect { () throws(AppStoreConnectError) in
            try await store.sendCreativeImage(to: library, fileName: fileName, referenceName: reference, data: data)
        }
        return (try? await store.libraryImage(id))?.isPlaceable == true ? .ready : .processing
    }

    /// `creative.json` を書き直す（`change` が書く必要があれば true を返す）。書けなければ知らせて次の見回りでやり直す
    @discardableResult
    nonisolated func updateCreativeFile(
        _ repo: RepositoryFullName,
        message: String,
        _ change: @escaping @Sendable (inout CreativeFile) -> Bool
    ) async -> CreativeFile? {
        let path = StatePath.creative(repo)
        let now = context.timestamp
        do {
            return try await context.writingResult { () throws(CommanderError) -> CreativeFile in
                do throws(StateFileStore.Failure) {
                    return try await context.files.update(CreativeFile.self, at: path, message: message) { file in
                        guard change(&file) else { return false }
                        file.updatedAt = now
                        return true
                    }.file
                } catch {
                    throw .files(error)
                }
            }
        } catch {
            await report("\(repo) のクリエイティブアセットの記録を書けない（\(error)）。次の見回りでやり直す")
            return nil
        }
    }
}
