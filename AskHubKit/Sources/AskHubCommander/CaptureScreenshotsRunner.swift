import AskHubBuild
import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 判断のカードのスクショを撮る（`captureScreenshots`）。epic の Mac で動く（`docs/renewal/flows.md` の「スクショ」）。
///
/// 撮る画面を選んだ見える仮決めごとに、Before（base との分岐点）と After（作業ブランチの先頭）を、リポジトリの撮れる画面の一覧の
/// 起動引数でアプリを起動して撮る。撮った画像は状態リポジトリ（`StatePath.screenshot`。同じコミット・画面は撮り直さない）と、
/// GitHub（最終 PR の本文に載せる。public で消せないので、デモのデータの画面だけを一覧に書く決まり）に上げ、最終 PR の本文のカードを書き直す。
///
/// 撮れなかったもの（ビルドが通らない・一覧に無い・GitHub に上げられない）は、わけを `note` に書いて成功で終える（最終 PR を止めない）。
/// 失敗で終えるのは、状態リポジトリを読み書きできない・作業ブランチを取り出せないなど、やり直せば済むときだけ
public struct CaptureScreenshotsRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .captureScreenshots) { target throws(TaskJobExit) in
            try await environment.exclusively(job.epic) { () throws(TaskJobExit) in
                // Before の写しはジョブのフォルダに取り出すので、終わったら消す
                let result: Result<JobResult, TaskJobExit>
                do throws(TaskJobExit) {
                    result = .success(try await capture(job, target))
                } catch {
                    result = .failure(error)
                }
                await environment.git.release(job.id)
                return try result.get()
            }
        }
    }

    private func capture(_ job: JobFile, _ target: FinalTarget) async throws(TaskJobExit) -> JobResult {
        guard let input = job.input(as: PullRequestInput.self), input.isValid else {
            throw .fail(.unexpected, "撮影の input に最終 PR と head が無い")
        }
        var outputs = AttemptFile.Outputs(pullRequest: input.pullRequest, commit: input.head)
        let file = try await environment.tasks.read(DecisionsFile.self, at: StatePath.decisions(job.repo, job.epic)) ?? DecisionsFile()
        let targets = file.items.filter { $0.visible == true && $0.scene != nil }
        let screens = file.screens ?? []
        guard let settings = target.settings.screenshots, let destination = settings.simulator, !targets.isEmpty || !screens.isEmpty else {
            return JobResult(outputs: outputs)
        }
        let environment = environment
        let pulls = environment.tasks.pullRequests(job.repo)
        let pull = try await environment.tasks.github("最終 PR を読む") { () throws(PullRequestError) in
            try await pulls.pullRequest(number: input.pullRequest)
        }
        try FinalJobEnvironment.checkDirection(pull, branches: target.branches)
        let checkout = try await environment.tasks.workspace { () throws(WorkspaceError) in
            try await environment.git.checkOutEpic(job.repo, epic: job.epic, branches: target.branches)
        }
        outputs.commit = checkout.head
        let base = try await environment.tasks.workspace { () throws(WorkspaceError) in
            try await environment.git.mergeBase(job.repo, branches: target.branches, head: checkout.head)
        }
        let scenes = Set(targets.compactMap(\.scene) + screens.map(\.scene))
        let camera = Camera(job: job, environment: environment, settings: settings, build: target.settings.build, destination: destination)
        // After: 作業ブランチの先頭（epic の作業場所。DerivedData が温まっている）
        let after = try await camera.shoot(scenes, commit: checkout.head, base: false) { () throws(TaskJobExit) in checkout.directory }
        // Before: base との分岐点。撮ってあれば取り出さない
        let before = try await camera.shoot(scenes, commit: base, base: true) { () throws(TaskJobExit) in
            try await environment.tasks.workspace { () throws(WorkspaceError) in
                try await environment.git.checkOutCommit(job.repo, job: job.id, commit: base, name: "base")
            }
        }
        var screenshots = Self.screenshots(of: targets, before: before, after: after, head: checkout.head)
        var changes = screens.map { screen in
            DecisionsFile.ScreenChange(
                scene: screen.scene,
                title: after.titles[screen.scene] ?? screen.title,
                screenshots: Self.shots(of: screen.scene, before: before, after: after, head: checkout.head)
            )
        }
        var uploader = Uploader(pulls: pulls, store: environment.context.store, previous: file)
        try await uploader.upload(&screenshots, &changes)
        let captured = file.capturing(screenshots, screens: changes)
        if !(await Self.rewriteBody(of: input.pullRequest, with: captured, target: target, pulls: pulls)) {
            let note = "最終 PR の本文を書き直せなかった"
            for id in screenshots.keys { screenshots[id]?.append(note: note) }
            for index in changes.indices { changes[index].screenshots?.append(note: note) }
        }
        outputs.screenshots = screenshots.isEmpty ? nil : screenshots
        outputs.screenChanges = changes.isEmpty ? nil : changes
        return JobResult(outputs: outputs)
    }

    /// 最終 PR の本文のカードと画面の変化を、撮ったもので書き直す。書けたかを返す（書けなくても、スクショは AskHub で見られるので止めない）
    static func rewriteBody(
        of pullRequest: Int,
        with decisions: DecisionsFile,
        target: FinalTarget,
        pulls: any PullRequestOperations
    ) async -> Bool {
        let body = FinalPullRequestBody.text(
            epic: target.epic, goal: target.goal, decisions: decisions, branches: target.branches, capturesScreenshots: true
        )
        do {
            try await pulls.updateBody(number: pullRequest, body: body)
            return true
        } catch {
            return false
        }
    }

    /// 1 つの版で撮ったもの（画面の id → 状態リポジトリのパス、撮れなかった画面 → わけ、撮った一覧の画面の説明）
    struct Shots: Equatable {
        var paths: [String: String] = [:]
        var failures: [String: String] = [:]
        var titles: [String: String] = [:]
    }

    /// 1 つの画面の Before / After と、撮れなかったわけ
    static func shots(of scene: String, before: Shots, after: Shots, head: String) -> DecisionsFile.Screenshots {
        var shots = DecisionsFile.Screenshots(before: before.paths[scene], after: after.paths[scene], head: head)
        if let failure = after.failures[scene] { shots.append(note: failure) }
        if let failure = before.failures[scene] { shots.append(note: failure) }
        return shots
    }

    /// 仮決めごとの Before / After と、撮れなかったわけ
    static func screenshots(
        of items: [DecisionsFile.Item],
        before: Shots,
        after: Shots,
        head: String
    ) -> [String: DecisionsFile.Screenshots] {
        var screenshots: [String: DecisionsFile.Screenshots] = [:]
        for item in items {
            guard let scene = item.scene else { continue }
            screenshots[item.id] = shots(of: scene, before: before, after: after, head: head)
        }
        return screenshots
    }
}

// MARK: - 撮る

extension CaptureScreenshotsRunner {
    /// 版ごとに撮って、状態リポジトリに置く
    struct Camera {
        var job: JobFile
        var environment: FinalJobEnvironment
        var settings: ScreenshotSettings
        var build: BuildSettings
        var destination: SimulatorDestination

        /// `scenes` を `commit` の版で撮る。状態リポジトリに置いてあるもの（同じコミット・画面）は撮り直さない。
        /// 写しは、撮るものがあるときだけ `checkout` で取り出し、そこにある撮れる画面の一覧の起動引数で撮る
        func shoot(
            _ scenes: Set<String>,
            commit: String,
            base: Bool,
            checkout: () async throws(TaskJobExit) -> URL
        ) async throws(TaskJobExit) -> Shots {
            let label = base ? "Before" : "After"
            var (shots, missing) = try await stored(scenes, commit: commit)
            guard !missing.isEmpty else { return shots }
            let directory = try await checkout()
            let list: ScreenshotScenesFile
            switch ScreenshotScenes.load(from: directory, path: settings.scenes) {
            case let .scenes(file):
                list = file
            case let .unavailable(reason):
                for scene in missing { shots.failures[scene] = "\(label) なし（\(reason)）" }
                return shots
            }
            for scene in list.scenes where scenes.contains(scene.id) { shots.titles[scene.id] = scene.title }
            for scene in missing where list.scene(scene) == nil {
                shots.failures[scene] = base ? "Before なし（この画面は epic で足した）" : "After なし（撮れる画面の一覧に無い）"
            }
            let known = missing.compactMap(list.scene)
            guard !known.isEmpty else { return shots }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("askhub-capture-\(job.id)-\(label)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: output) }
            let request = CaptureRequest(
                settings: build,
                sourceDirectory: directory,
                derivedData: environment.builds.screenshotDerivedData(of: job.epic, base: base),
                scenes: known,
                output: output
            )
            let (builds, destination) = (environment.builds, destination)
            let outcome: CaptureOutcome? = await environment.tasks.slots.withSlot { slot in
                try? await builds.capture(request, slot: slot, destination: destination)
            }
            guard let outcome else { throw .fail(.macOffline, "ワーカーを止めたので、撮影を中断した") }
            try await place(outcome, of: known.map(\.id), commit: commit, label: label, into: &shots)
            return shots
        }

        /// 状態リポジトリに置いてある画面（`shots.paths`）と、まだ撮っていない画面
        private func stored(_ scenes: Set<String>, commit: String) async throws(TaskJobExit) -> (Shots, [String]) {
            var shots = Shots()
            var missing: [String] = []
            for scene in scenes.sorted() {
                let path = StatePath.screenshot(job.repo, job.epic, commit: commit, scene: scene)
                if try await read(path) != nil { shots.paths[scene] = path } else { missing.append(scene) }
            }
            return (shots, missing)
        }

        /// 撮れた画像を状態リポジトリに置き、撮れなかった画面にはわけを書く
        private func place(
            _ outcome: CaptureOutcome,
            of scenes: [String],
            commit: String,
            label: String,
            into shots: inout Shots
        ) async throws(TaskJobExit) {
            for scene in scenes {
                if let failure = outcome.failure(of: scene) {
                    shots.failures[scene] = "\(label) を撮れなかった（\(failure)）"
                    continue
                }
                guard let file = outcome.images[scene], let data = try? Data(contentsOf: file) else { continue }
                let path = StatePath.screenshot(job.repo, job.epic, commit: commit, scene: scene)
                try await write(path, data: data, message: "判断のカードのスクショ（\(scene) の \(label)）を置く")
                shots.paths[scene] = path
            }
        }

        private func read(_ path: String) async throws(TaskJobExit) -> StoredBlob? {
            do {
                return try await environment.context.store.read(path)
            } catch {
                throw .state(.store(error))
            }
        }

        /// 新しく置く。同じパスがもうある（前の試行が置いた）なら、そのままにする
        private func write(_ path: String, data: Data, message: String) async throws(TaskJobExit) {
            do {
                _ = try await environment.context.store.write(path, data: data, replacing: nil, message: message)
            } catch .conflict {
                return
            } catch {
                throw .state(.store(error))
            }
        }
    }
}

// MARK: - GitHub に上げる

extension CaptureScreenshotsRunner {
    /// 撮った画像を GitHub に上げ、URL を書く。前に上げた同じ画像（同じパス）の URL は使い回す。
    /// 1 枚でも上げられなければ（権限が無い・上限など）、残りは上げずに、わけを書く
    struct Uploader {
        var pulls: any PullRequestOperations
        var store: any StateStore
        /// 上げた画像（状態リポジトリのパス → URL）。前の `decisions.json` に書いた URL から始める
        var urls: [String: String] = [:]
        /// 上げられなかったわけ。あれば残りは上げない
        var problem: String?

        init(pulls: any PullRequestOperations, store: any StateStore, previous: DecisionsFile) {
            self.pulls = pulls
            self.store = store
            for shots in previous.items.compactMap(\.screenshots) + (previous.screens ?? []).compactMap(\.screenshots) {
                if let path = shots.before, let url = shots.beforeURL { urls[path] = url }
                if let path = shots.after, let url = shots.afterURL { urls[path] = url }
            }
        }

        /// 仮決めごとと画面の変化の画像を上げる（仮決めの id の順、画面の変化の順）
        mutating func upload(
            _ screenshots: inout [String: DecisionsFile.Screenshots],
            _ changes: inout [DecisionsFile.ScreenChange]
        ) async throws(TaskJobExit) {
            for id in screenshots.keys.sorted() {
                guard var shots = screenshots[id] else { continue }
                await upload(&shots)
                screenshots[id] = shots
            }
            for index in changes.indices {
                guard var shots = changes[index].screenshots else { continue }
                await upload(&shots)
                changes[index].screenshots = shots
            }
        }

        private mutating func upload(_ shots: inout DecisionsFile.Screenshots) async {
            for side in [\DecisionsFile.Screenshots.before, \.after] {
                guard let path = shots[keyPath: side], urls[path] == nil, problem == nil else { continue }
                do {
                    urls[path] = try await upload(path)
                } catch {
                    problem = "GitHub に上げられなかった（\(error.summary)）。AskHub のクライアントで見られる"
                }
            }
            shots.beforeURL = shots.before.flatMap { urls[$0] }
            shots.afterURL = shots.after.flatMap { urls[$0] }
            if let problem, [shots.before, shots.after].contains(where: { path in path.map { urls[$0] == nil } ?? false }) {
                shots.append(note: problem)
            }
        }

        private func upload(_ path: String) async throws(UploadError) -> String {
            let blob: StoredBlob?
            do {
                blob = try await store.read(path)
            } catch {
                throw .store(error)
            }
            guard let blob else { throw .missing }
            let name = String(path.split(separator: "/").last ?? "screenshot.png")
            do {
                return try await pulls.uploadAttachment(blob.data, name: name, contentType: "image/png")
            } catch {
                throw .github(error)
            }
        }
    }

    enum UploadError: Error {
        case store(StateStoreError)
        case github(PullRequestError)
        case missing

        var summary: String {
            switch self {
            case .store: "状態リポジトリから読めない"
            case .missing: "状態リポジトリに無い"
            case .github(.notFound): "書き込みの権限が無い"
            case .github(.rateLimited): "GitHub の上限に当たった"
            case let .github(error): "\(error)"
            }
        }
    }
}

extension DecisionsFile.Screenshots {
    /// 撮れなかったわけを足す（長さの上限までに切る）
    mutating func append(note text: String) {
        let joined = [note, text].compactMap(\.self).joined(separator: "・")
        note = String(joined.unicodeScalars.prefix(Self.maximumNoteLength).map(Character.init))
    }
}
