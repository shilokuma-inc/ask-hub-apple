import AskHubProtocol
import AskHubStateStore
import Foundation

/// 写しの元になる状態（無いファイルは nil）
struct MirrorState: Sendable {
    var questions: QuestionsFile?
    var goal: GoalFile?
    var readiness: ReadinessFile?
}

/// 照らし合わせの途中で作った・目印で見つけた写しの id（状態リポジトリに戻す）
struct CreatedCopies: Sendable {
    /// 質問の id → コメントの id
    var questions: [String: String] = [:]
    var goal: String?

    var isEmpty: Bool { questions.isEmpty && goal == nil }
}

/// Discussion にある、自分が書いた（`viewerDidAuthor`）コメント
struct ExistingCopies {
    var byID: [String: DiscussionThread.Comment] = [:]
    var byMarker: [JSONValue: DiscussionThread.Comment] = [:]

    init(_ thread: DiscussionThread) {
        for comment in thread.comments where comment.post.viewerDidAuthor {
            byID[comment.post.id] = comment
            if let marker = ProtocolMarker.parse(comment.post.body)?.value, byMarker[marker] == nil { byMarker[marker] = comment }
        }
    }
}

/// 照らし合わせたコメント
struct PlacedCopy {
    var id: String
    var replies: [DiscussionPost]
    /// 作った・目印で見つけたので、id を状態に戻す
    var isNew: Bool
}

extension DiscussionMirror {
    // MARK: - Discussion

    /// epic の Discussion。番号が無ければ、作った後に番号を戻す前に止まっていないかを目印で探し、無ければ作る。番号は状態に戻す
    func thread(of epic: EpicFile, copies: DiscussionCopies) async throws(MirrorError) -> DiscussionThread {
        if let number = epic.discussion { return try await existingThread(epic.repo, number: number) }
        let api = discussions(epic.repo)
        let since = epic.createdAt.date.addingTimeInterval(-TimeInterval(settings.clockSkew.components.seconds))
        let marker = copies.request.marker
        let found = try await Self.github { () throws(DiscussionError) in try await api.discussions(epic.repo, createdSince: since) }
            .first { $0.viewerDidAuthor && ProtocolMarker.parse($0.body)?.value == marker }
        if let found {
            try await writeBack(discussion: found.number, of: epic)
            return try await existingThread(epic.repo, number: found.number)
        }
        let (repository, category) = try await usableRepository(epic.repo)
        let created: DiscussionSummary
        do {
            created = try await api.createDiscussion(
                repository: repository.id, category: category.id, title: copies.title, body: copies.request.text
            )
        } catch {
            forgetRepository(epic.repo)
            throw .github(error)
        }
        log("epic \(epic.id) の Discussion を作った（\(epic.repo)#\(created.number)）")
        try await writeBack(discussion: created.number, of: epic)
        return DiscussionThread(
            id: created.id, number: created.number, title: copies.title, body: copies.request.text, viewerDidAuthor: true
        )
    }

    private func existingThread(_ repo: RepositoryFullName, number: Int) async throws(MirrorError) -> DiscussionThread {
        let api = discussions(repo)
        let thread = try await Self.github { () throws(DiscussionError) in try await api.discussion(repo, number: number) }
        guard let thread else {
            // 空の結果を理由に作り直さない（人が消した Discussion を勝手に戻さない。GitHub の障害で空が返ることもある）
            let message = "\(repo) の Discussion #\(number) が見つからない（消された・移された）。作り直さない"
            throw .inconsistent(AttemptFailure(failureClass: .unexpected, message: message))
        }
        guard thread.viewerDidAuthor else {
            throw .inconsistent(AttemptFailure(failureClass: .unexpected, message: "\(repo) の Discussion #\(number) は司令塔が書いたものでない。写さない"))
        }
        return thread
    }

    // MARK: - コメント

    /// Discussion の本文と、質問・説明・回答・ゴールの写しを照らし合わせ、作った写しの id を状態に戻す
    func reconcile(
        _ thread: DiscussionThread,
        with copies: DiscussionCopies,
        epic: EpicFile,
        state: MirrorState
    ) async throws(MirrorError) {
        let api = discussions(epic.repo)
        let (title, body) = (copies.title, copies.request.text)
        if thread.title != title || !Self.same(thread.body, body) {
            try await Self.github { () throws(DiscussionError) in try await api.updateDiscussion(thread.id, title: title, body: body) }
        }
        let existing = ExistingCopies(thread)
        let pairs = state.questions?.questions.compactMap { question in question.comment.map { (question.id, $0) } } ?? []
        let storedQuestions = Dictionary(pairs) { first, _ in first }
        let ids = Array(storedQuestions.values) + [state.goal?.comment].compactMap(\.self)
        let board = Board(
            api: api, thread: thread, existing: existing, deleted: try await deletedCopies(ids, in: existing, api: api)
        )
        var created = CreatedCopies()
        do throws(MirrorError) {
            for question in copies.questions {
                let placed = try await place(question.copy, stored: storedQuestions[question.id], on: board)
                guard let placed else { continue }
                if placed.isNew { created.questions[question.id] = placed.id }
                try await placeReplies(question.replies, under: placed, on: board)
            }
            if let goal = copies.goal {
                let placed = try await place(goal, stored: state.goal?.comment, on: board)
                if let placed, placed.isNew { created.goal = placed.id }
            }
        } catch {
            // 作った写しの id は、途中で失敗しても状態に戻しておく（戻せなくても、次の周で目印から見つける）
            try? await writeBack(created, of: epic)
            throw error
        }
        try await writeBack(created, of: epic)
    }

    /// 状態に戻した id のうち、消された写し（作り直さない）。一覧に無いのに消されてもいなければ、一覧が欠けているので、重ならないよう何も作らずにやり直す
    private func deletedCopies(
        _ ids: [String],
        in existing: ExistingCopies,
        api: any DiscussionAPI
    ) async throws(MirrorError) -> Set<String> {
        let absent = Set(ids.filter { existing.byID[$0] == nil })
        guard !absent.isEmpty else { return [] }
        let missing = try await Self.github { () throws(DiscussionError) in try await api.missing(absent.sorted()) }
        guard absent.isSubset(of: missing) else {
            let message = "Discussion のコメントの一覧に、ある写しが載っていない（一覧が欠けている）。何も作らずにやり直す"
            throw .inconsistent(AttemptFailure(failureClass: .githubOutage, message: message))
        }
        log("消された写し（\(absent.sorted().joined(separator: "・"))）は作り直さない")
        return absent
    }

    /// 1 つの Discussion の写しを照らし合わせるときに使うもの
    private struct Board {
        /// その Discussion のリポジトリの持ち主のトークンで読み書きするもの
        var api: any DiscussionAPI
        var thread: DiscussionThread
        var existing: ExistingCopies
        /// 消された写し（作り直さない）
        var deleted: Set<String>
    }

    /// Discussion への直接のコメント（質問・ゴール）を照らし合わせる。消された写しなら nil
    private func place(_ copy: DiscussionCopies.Copy, stored: String?, on board: Board) async throws(MirrorError) -> PlacedCopy? {
        if let stored {
            guard !board.deleted.contains(stored) else { return nil }
            guard let comment = board.existing.byID[stored] else {
                throw .inconsistent(AttemptFailure(failureClass: .githubOutage, message: "写し \(stored) がコメントの一覧に無い"))
            }
            try await updateIfChanged(comment.post, to: copy.text, api: board.api)
            return PlacedCopy(id: stored, replies: comment.replies, isNew: false)
        }
        // 作った後、id を状態に戻す前に止まっていれば、目印で見つける
        if let comment = board.existing.byMarker[copy.marker] {
            try await updateIfChanged(comment.post, to: copy.text, api: board.api)
            return PlacedCopy(id: comment.post.id, replies: comment.replies, isNew: true)
        }
        let (api, discussion, text) = (board.api, board.thread.id, copy.text)
        let id = try await Self.github { () throws(DiscussionError) in
            try await api.addComment(to: discussion, replyingTo: nil, body: text)
        }
        return PlacedCopy(id: id, replies: [], isNew: true)
    }

    /// 質問のコメントへの返信（説明・回答）を照らし合わせる。返信は id を状態に持たないので、目印で探す
    private func placeReplies(_ replies: [DiscussionCopies.Copy], under parent: PlacedCopy, on board: Board) async throws(MirrorError) {
        for reply in replies {
            let marker = reply.marker
            if let post = parent.replies.first(where: { $0.viewerDidAuthor && ProtocolMarker.parse($0.body)?.value == marker }) {
                try await updateIfChanged(post, to: reply.text, api: board.api)
            } else {
                let (api, discussion, text) = (board.api, board.thread.id, reply.text)
                _ = try await Self.github { () throws(DiscussionError) in
                    try await api.addComment(to: discussion, replyingTo: parent.id, body: text)
                }
            }
        }
    }

    private func updateIfChanged(_ post: DiscussionPost, to text: String, api: any DiscussionAPI) async throws(MirrorError) {
        guard !Self.same(post.body, text) else { return }
        try await Self.github { () throws(DiscussionError) in try await api.updateComment(post.id, body: text) }
    }

    /// 本文と目印が同じか（GitHub が改行を `\r\n` にして返すことがあるので、目印の読み方でそろえて比べる）
    static func same(_ current: String, _ text: String) -> Bool {
        guard let current = ProtocolMarker.parse(current), let wanted = ProtocolMarker.parse(text) else { return false }
        return current == wanted
    }

    // MARK: - 状態に戻す

    /// Discussion の番号を epic に戻す。すでに番号があれば、そのまま
    nonisolated func writeBack(discussion number: Int, of epic: EpicFile) async throws(MirrorError) {
        let context = context
        try await Self.state { () throws(CommanderError) in
            try await context.lock.withLock { () throws(CommanderError) in
                do throws(StateFileStore.Failure) {
                    try await context.files.update(EpicFile.self, at: StatePath.epic(epic.repo, epic.id), message: "Discussion の写しの番号を書く") {
                        guard $0.discussion == nil else { return false }
                        $0.discussion = number
                        return true
                    }
                } catch {
                    throw .files(error)
                }
            }
        }
    }

    /// 作った写しの id を、質問の一覧とゴールに戻す。すでに id があれば、そのまま
    nonisolated func writeBack(_ created: CreatedCopies, of epic: EpicFile) async throws(MirrorError) {
        guard !created.isEmpty else { return }
        let context = context
        try await Self.state { () throws(CommanderError) in
            try await context.lock.withLock { () throws(CommanderError) in
                do throws(StateFileStore.Failure) {
                    if !created.questions.isEmpty {
                        let path = StatePath.questions(epic.repo, epic.id)
                        try await context.files.update(QuestionsFile.self, at: path, message: "Discussion の写しの id を書く") { file in
                            var changed = false
                            for index in file.questions.indices where file.questions[index].comment == nil {
                                guard let id = created.questions[file.questions[index].id] else { continue }
                                file.questions[index].comment = id
                                changed = true
                            }
                            return changed
                        }
                    }
                    if let goal = created.goal {
                        let path = StatePath.goal(epic.repo, epic.id)
                        try await context.files.update(GoalFile.self, at: path, message: "Discussion の写しの id を書く") {
                            guard $0.comment == nil else { return false }
                            $0.comment = goal
                            return true
                        }
                    }
                } catch {
                    throw .files(error)
                }
            }
        }
    }

    // MARK: - 読む

    nonisolated func stateOf(_ epic: EpicFile) async throws(MirrorError) -> MirrorState {
        let context = context
        return try await Self.state { () throws(CommanderError) in
            MirrorState(
                questions: try await context.read(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id)),
                goal: try await context.read(GoalFile.self, at: StatePath.goal(epic.repo, epic.id)),
                readiness: try await context.read(ReadinessFile.self, at: StatePath.readiness(epic.repo, epic.id))
            )
        }
    }

    /// 状態リポジトリの失敗を、写しの失敗にする（呼んだ側と同じ isolation で動かす）
    static func state<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(CommanderError) -> T
    ) async throws(MirrorError) -> T {
        do {
            return try await body()
        } catch {
            throw .state(error)
        }
    }

    /// GitHub の失敗を、写しの失敗にする（呼んだ側と同じ isolation で動かす）
    static func github<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws(DiscussionError) -> T
    ) async throws(MirrorError) -> T {
        do {
            return try await body()
        } catch {
            throw .github(error)
        }
    }
}
