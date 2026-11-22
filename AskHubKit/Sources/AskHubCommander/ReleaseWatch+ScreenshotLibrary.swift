import AskHubProtocol
import Foundation

/// 撮って比べた画像を、人が確かめる前に App Store Connect のライブラリに上げておく（`docs/renewal/store-screenshots.md` の「先に上げておく」。
/// 2026-11-22 のユーザーの決定の 2）。配置はしない（審査に出すときに置く）。
///
/// 比べ終えたら、撮影を「撮っている」のまま取り込みの数（`library`）を持たせて書き、見回りの周で、差のある画面の元の画像を上げ（予約 → 送る →
/// `uploaded`。処理は待たない）、処理の様子を読む（5 分空ける）。すべて置ける（か受け付けられない）になったら決着させる。3 時間で打ち切る。
/// 画像は参照名（`askhub-<MD5>`）で探すので、同じ画像は言語・組・版をまたいで 1 回だけ上げ、途中で止まってもやり直せば同じになる
extension ReleaseWatch {
    /// 取り込みの様子を読む間隔
    static let libraryCheckInterval: TimeInterval = 5 * 60
    /// 取り込みを打ち切るまでの時間（混む日は 1 枚 20 分を超え、何時間も止まる日もあるので、審査に出す準備をずっと止めない）
    static let libraryTimeout: TimeInterval = 3 * 60 * 60
    /// 元の画像を常時オンの Mac で読めない画面のわけ（上げられないので、受け付けられなかった画面にする）
    static let unreadableOriginal = "撮った元の画像を常時オンの Mac で読めない（撮り直す）"

    /// ライブラリに上げる 1 枚（同じ画像は 1 つ）と、その画像を使う画面
    struct LibraryUpload {
        var checksum: String
        var fileName: String
        var data: Data
        var shots: [SubmissionFile.ShotReference]

        var referenceName: String { AppStoreScreenshot.referenceName(checksum: checksum) }
    }

    /// 差のある画面（受け付けられなかったものを除く）の元の画像を、同じ画像ごとにまとめる
    static func libraryUploads(of screenshots: SubmissionFile.StoreScreenshots, originals: URL) -> [LibraryUpload] {
        libraryShots(of: screenshots, originals: originals).uploads
    }

    /// 差のある画面（受け付けられなかったものを除く）を、上げる画像（同じ画像ごと）と、元の画像を常時オンの Mac で読めない画面に分ける
    static func libraryShots(
        of screenshots: SubmissionFile.StoreScreenshots,
        originals: URL
    ) -> (uploads: [LibraryUpload], unreadable: [SubmissionFile.ShotReference]) {
        var uploads: [LibraryUpload] = []
        var unreadable: [SubmissionFile.ShotReference] = []
        for set in screenshots.sets {
            for shot in set.shots where shot.changed && shot.rejected == nil {
                let target = StoreScreenshotTarget(displayType: set.displayType, locale: set.locale)
                let file = StoreScreenshotComparer.original(in: originals, target: target, index: shot.index)
                let reference = SubmissionFile.ShotReference(displayType: set.displayType, locale: set.locale, index: shot.index)
                guard let data = try? Data(contentsOf: file) else {
                    unreadable.append(reference)
                    continue
                }
                let checksum = AppStoreScreenshot.checksum(of: data)
                if let index = uploads.firstIndex(where: { $0.checksum == checksum }) {
                    uploads[index].shots.append(reference)
                } else {
                    let name = "\(set.displayType)-\(set.locale)-\(shot.index).png"
                    uploads.append(LibraryUpload(checksum: checksum, fileName: name, data: data, shots: [reference]))
                }
            }
        }
        return (uploads, unreadable)
    }

    /// 比べ終えた結果（`captured`）に、ライブラリに上げる画像があれば、取り込みを待つ印（`capturing` と `library`）にする。
    /// 元の画像を読めない画面は、上げられないので受け付けられなかった画面にする（すべて読めなければ、待たずに決着させる）
    func awaitingLibrary(_ result: SubmissionFile.StoreScreenshots, originals: URL) -> SubmissionFile.StoreScreenshots {
        guard result.state == .captured else { return result }
        let (uploads, unreadable) = Self.libraryShots(of: result, originals: originals)
        var waiting = result
        let rejected = Dictionary(uniqueKeysWithValues: unreadable.map { ($0, Self.unreadableOriginal) })
        waiting.sets = Self.marking(result.sets, rejected: rejected)
        guard !uploads.isEmpty else { return waiting }
        waiting.state = .capturing
        waiting.finishedAt = nil
        waiting.library = .init(total: uploads.count, ready: 0, sentAt: context.timestamp)
        return waiting
    }

    /// 取り込みを進める（上げていない画像を上げ、処理の様子を読む）。`force` でなければ 5 分空ける
    func advanceLibraryUpload(_ file: SubmissionFile, settings: RepositoryFile, force: Bool = false) async -> SubmissionFile {
        let key = Self.screenshotKey(file)
        if !force, let checked = screenshotRunsCheckedAt[key], context.now().timeIntervalSince(checked) < Self.libraryCheckInterval {
            return file
        }
        screenshotRunsCheckedAt[key] = context.now()
        let advanced = await submissionStep(.screenshots, file) { file in
            guard var shots = file.screenshots, shots.state == .capturing, var library = shots.library, let commit = shots.commit else {
                return nil
            }
            guard let capturer = self.screenshots else {
                throw ReleaseStepProblem("撮った元の画像を置く場所が司令塔に無い（スクショを撮る道具の設定が無い）", needsHuman: true)
            }
            let originals = capturer.originals(file.repo, version: file.version, commit: commit)
            let (uploads, unreadable) = Self.libraryShots(of: shots, originals: originals)
            let timedOut = self.context.now().timeIntervalSince(library.sentAt.date) >= Self.libraryTimeout
            // 読めない画像がある周は、打ち切る時間を過ぎていなければやり直す（過ぎていれば、読めなかった画像も打ち切る）
            let (states, sent) = try await self.sendAndRead(uploads, of: file.repo, settings: settings, giveUp: timedOut)
            // 画像を送ったら、Apple の処理の時間をそこから数え直す（送る前の待ちを含めない）
            if sent { library.sentAt = self.context.timestamp }
            var rejected = Self.rejectedShots(uploads, states: states, timedOut: timedOut && !sent)
            for shot in unreadable { rejected[shot] = Self.unreadableOriginal }
            library.ready = uploads.filter { states[$0.checksum]?.isPlaceable == true }.count
            shots.sets = Self.marking(shots.sets, rejected: rejected)
            shots.library = library
            // すべて置ける（か受け付けられない）になった。受け付けられなかった画面は前のままにするしかない
            if uploads.allSatisfy({ states[$0.checksum]?.isPlaceable == true || $0.shots.contains { rejected[$0] != nil } }) {
                shots.state = .captured
                shots.finishedAt = self.context.timestamp
                self.log("\(file.repo) の \(file.version) のスクショの取り込みが終わった（\(library.ready) / \(library.total) 枚）")
            }
            guard shots != file.screenshots else { return nil }
            var file = file
            file.screenshots = shots
            return file
        }
        if advanced.screenshots?.state.isSettled == true { screenshotRunsCheckedAt[key] = nil }
        return advanced
    }

    /// 受け付けられなかった画面とわけ。処理に失敗した画像の画面と、打ち切ったときに置ける状態になっていない画像の画面
    static func rejectedShots(
        _ uploads: [LibraryUpload],
        states: [String: AppStoreLibraryImage],
        timedOut: Bool
    ) -> [SubmissionFile.ShotReference: String] {
        var rejected: [SubmissionFile.ShotReference: String] = [:]
        for upload in uploads {
            let image = states[upload.checksum]
            let reason: String
            if image?.isFailed == true {
                reason = "App Store Connect が受け付けなかった（\(image?.details ?? "理由は示されていない")）"
            } else if image?.isPlaceable != true, timedOut {
                reason = "App Store Connect の取り込みが \(Int(libraryTimeout / 3600)) 時間で終わらない"
            } else {
                continue
            }
            for shot in upload.shots { rejected[shot] = reason }
        }
        return rejected
    }

    /// 受け付けられなかった画面に、わけを書く
    static func marking(
        _ sets: [SubmissionFile.ScreenshotSet],
        rejected: [SubmissionFile.ShotReference: String]
    ) -> [SubmissionFile.ScreenshotSet] {
        sets.map { set in
            var set = set
            set.shots = set.shots.map { shot in
                var shot = shot
                let reference = SubmissionFile.ShotReference(displayType: set.displayType, locale: set.locale, index: shot.index)
                if let reason = rejected[reference] { shot.rejected = reason }
                return shot
            }
            return set
        }
    }

    /// 上げていない画像を上げ、画像ごとの処理の様子を返す（MD5 → 画像）。処理中の画像は消さずに待ち、予約だけして送り終えなかった画像は上げ直す。
    /// 受け付けられなかった画像は上げ直さない（同じ画像は、また受け付けられない）
    /// `giveUp` なら、App Store Connect のアプリを探せない・画像を読めない・送れないときも投げず、読めた分だけを返す（打ち切りの判定を止めない）。
    /// 画像を送った後に読めなくなったときも投げず、読めた分だけを返す（送った時刻を残し、そこから数え直すため。残りは次の周に読む）。
    /// `sent` は、この周に画像を送ったか
    private func sendAndRead(
        _ uploads: [LibraryUpload],
        of repo: RepositoryFullName,
        settings: RepositoryFile,
        giveUp: Bool
    ) async throws -> (states: [String: AppStoreLibraryImage], sent: Bool) {
        var states: [String: AppStoreLibraryImage] = [:]
        var sent = false
        do {
            let (store, app) = try await submissionApp(repo, settings: settings)
            let library = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.assetLibrary(of: app.id) }
            for upload in uploads {
                let found = try await appStoreConnect { () throws(AppStoreConnectError) in
                    try await store.libraryImages(in: library, referenceName: upload.referenceName)
                }
                let known = found.first(where: \.isPlaceable) ?? found.first(where: \.isProcessing) ?? found.first(where: \.isFailed)
                if let image = known {
                    states[upload.checksum] = image
                    continue
                }
                for stale in found { try? await store.deleteImage(stale.id) }
                let id = try await appStoreConnect { () throws(AppStoreConnectError) in
                    try await store.sendImage(
                        to: library, fileName: upload.fileName, referenceName: upload.referenceName, data: upload.data
                    )
                }
                sent = true
                states[upload.checksum] = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.libraryImage(id) }
            }
        } catch {
            guard giveUp || sent else { throw error }
            report(giveUp
                ? "App Store Connect のライブラリを読めない画像がある（\(error)）。打ち切る時間を過ぎたので、読めなかった画像は前のままにする"
                : "App Store Connect に送った画像の様子を読めない（\(error)）。送った時刻は残し、次の周に読み直す")
        }
        return (states, sent)
    }
}
