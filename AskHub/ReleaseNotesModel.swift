import AskHubKit
import Foundation
import Observation

/// 準備中のリリースの最新情報（whatsNew）の確認・修正・確定（Discussion #605 の Q5）。
/// 下書き（`AppStore/whats-new-draft.json`）か確定済みの本文を言語ごとに出して直し、「確定して反映」で
/// 最新情報の確定のワークフロー（`release-notes.yml`）を release ブランチで起動する。状態の読み取りは `ReleaseRequestModel` が行い、`update` で渡す
@MainActor
@Observable
final class ReleaseNotesModel {
    struct Dispatch: Equatable {
        /// 起動した時刻（端末の時計）。「起動した」状態を保つ最長の時間を数えるのに使う
        var date: Date
        /// 起動したときに出ていた、このリリースの直近の run の id（無ければ `nil`）。これより大きい id の run が出たら、起動した run とみなす
        var previousRunID: Int?
    }

    /// 1 つのリリースの入力中の本文
    private struct Editing {
        var languages: [String]
        var texts: [String: String]
        var loadedTexts: [String: String]
    }

    /// 1 つの言語の本文の上限（App Store Connect の whatsNew の上限。`Tools/upload_metadata.py` と同じく Unicode のスカラー値で数える）
    static let maxLength = 4000

    /// 読んだリポジトリ
    private(set) var repository: String?
    /// 読んだ準備中のリリースの進み具合（無ければ `nil`）
    private(set) var progress: ReleaseProgress?
    /// 直す言語（`AppStore/languages.json` の順。無ければ下書きの言語）
    private(set) var languages: [String] = []
    /// 言語ごとの入力中の本文
    var texts: [String: String] = [:]
    /// 読んだ本文（下書きか、確定済みの本文）。入力中の本文が読んだときのままなら、読み直したときに新しい本文に入れ替える
    private(set) var loadedTexts: [String: String] = [:]
    /// リリースの状態を読み直しているか（`ReleaseRequestModel` が設定する）
    var isReading = false
    private(set) var isConfirming = false
    private(set) var errorMessage: String?
    /// リリースの状態を読み直せなかった理由（読めたら `nil`）。前に読んだ進み具合と入力中の本文は残したまま出す
    private(set) var readFailure: String?
    /// `errorMessage` が送らなかった理由か（次の読み取りの成功で消す）
    private var errorIsNotSentReason = false
    /// 別のリリースに切り替える前に直していた本文（`<リポジトリ> <バージョン>` → 本文）。戻ってきたら入力中の本文に戻す
    @ObservationIgnored private var editingByRelease: [String: Editing] = [:]
    /// アプリから起動したリリース（`<リポジトリ> <バージョン>`）。起動より新しい run が出るまで「起動した」状態を保ち、二重に起動しない
    private(set) var dispatched: [String: Dispatch] = [:]
    /// 起動した後に、リリースの状態を読み直す
    @ObservationIgnored var onNeedsRefresh: (@MainActor () async -> Void)?

    private let tokenStore: any TokenStore
    private let makeWorkflow: @Sendable (_ token: String, _ file: String) -> any WorkflowProviding
    private let dispatchRefreshDelay: Duration

    init(
        tokenStore: any TokenStore,
        makeWorkflow: @escaping @Sendable (_ token: String, _ file: String) -> any WorkflowProviding,
        dispatchRefreshDelay: Duration
    ) {
        self.tokenStore = tokenStore
        self.makeWorkflow = makeWorkflow
        self.dispatchRefreshDelay = dispatchRefreshDelay
    }

    var version: ReleaseVersion? {
        progress?.version
    }

    var notes: ReleaseNotes? {
        progress?.releaseNotes
    }

    /// 下書き（無ければ `nil`）
    var draft: WhatsNewDraft? {
        if case .draft(let draft) = notes?.status {
            return draft
        }
        return nil
    }

    // MARK: - 読み取りの反映

    /// 読み直したリリースの状態を反映する。リポジトリかバージョンが変わったら、入力中の本文をそのリリースのもの
    /// （前に直していればその本文、無ければ読んだ本文）に入れ替える。前のリリースの直した本文は `editingByRelease` に残す。
    /// 同じリリースなら、直していない言語だけを新しい本文に入れ替える（直した本文は消さない）
    func update(repository: String?, progress: ReleaseProgress?) {
        let isSameRelease = repository == self.repository && progress?.version == self.progress?.version
        if !isSameRelease, let previousKey = dispatchKey {
            // リポジトリを切り替えて戻ってきたときに、直した本文が黙って消えないようにする
            editingByRelease[previousKey] = isEdited ? Editing(languages: languages, texts: texts, loadedTexts: loadedTexts) : nil
        }
        self.repository = repository
        self.progress = progress
        readFailure = nil
        if errorIsNotSentReason || !isSameRelease {
            errorMessage = nil
            errorIsNotSentReason = false
        }
        if !isSameRelease {
            let editing = dispatchKey.flatMap { editingByRelease.removeValue(forKey: $0) }
            languages = editing?.languages ?? []
            texts = editing?.texts ?? [:]
            loadedTexts = editing?.loadedTexts ?? [:]
        }
        if case .failed = progress?.notes {
            // 最新情報だけ読めなかった。読んだ本文（直したかを見分ける元）と言語は前のままにする
            // （空にすると、次に読めたときに直していない本文まで「直した」扱いで残る）。確定は blockingReason で止める
            clearDispatchedIfRunStarted()
            return
        }
        let newTexts = Self.texts(of: progress?.releaseNotes)
        languages = Self.languages(of: progress?.releaseNotes)
        for language in languages where texts[language] == nil || texts[language] == loadedTexts[language] {
            texts[language] = newTexts[language] ?? ""
        }
        loadedTexts = newTexts
        clearDispatchedIfRunStarted()
    }

    /// リリースの状態を読み直せなかったことを反映する。前に読んだ進み具合と入力中の本文は残す（別のリポジトリを読めなかったときは何もしない）
    func readFailed(repository: String, message: String) {
        guard repository == self.repository, progress != nil else {
            return
        }
        readFailure = message
    }

    /// 読んだ本文。下書きがあれば下書き、無ければこのバージョンで確定した本文
    private static func texts(of notes: ReleaseNotes?) -> [String: String] {
        guard let notes else {
            return [:]
        }
        if case .draft(let draft) = notes.status {
            // 下書きに無い言語は、確定済みの本文があればそれを出す
            return notes.confirmedTexts.merging(draft.whatsNew) { _, draft in draft }
        }
        return notes.confirmedTexts
    }

    private static func languages(of notes: ReleaseNotes?) -> [String] {
        guard let notes else {
            return []
        }
        if !notes.languages.isEmpty {
            return notes.languages
        }
        if case .draft(let draft) = notes.status {
            return draft.whatsNew.keys.sorted()
        }
        return []
    }

    // MARK: - 検査

    /// 本文の長さ（`Tools/upload_metadata.py` の `len()` と同じく Unicode のスカラー値で数える）
    static func length(of text: String) -> Int {
        trimmed(text).unicodeScalars.count
    }

    /// 送る本文（前後の空白・改行を外す）
    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 言語の本文の問題（無ければ `nil`）
    func problem(for language: String) -> String? {
        let length = Self.length(of: texts[language] ?? "")
        if length == 0 {
            return "空です"
        }
        if length > Self.maxLength {
            return "\(Self.maxLength) 字を超えています（\(length) 字）"
        }
        return nil
    }

    /// 本文を直したか（読んだ本文と違う言語がある）
    var isEdited: Bool {
        languages.contains { texts[$0] != loadedTexts[$0] }
    }

    func isDispatchPending(now: Date = .now) -> Bool {
        guard let key = dispatchKey, let dispatch = dispatched[key] else {
            return false
        }
        return now.timeIntervalSince(dispatch.date) <= ReleaseRequestModel.dispatchPendingLimit
    }

    private var dispatchKey: String? {
        guard let repository, let version else {
            return nil
        }
        return "\(repository) \(version)"
    }

    /// 「確定して反映」を押せない理由（押せるなら `nil`）
    func blockingReason(now: Date = .now) -> String? {
        guard let progress else {
            return "準備中のリリースがありません"
        }
        if let reason = readingBlockingReason(progress) {
            return reason
        }
        if let reason = workflowBlockingReason(progress.notesWorkflow) {
            return reason
        }
        if isDispatchPending(now: now) {
            return "最新情報の確定を起動しました。run が始まるまで少し待ってから更新してください"
        }
        if progress.notesWorkflow.run?.isRunning == true {
            return "最新情報の確定の run が実行中です。終わってから確定してください"
        }
        if progress.prepareRun?.isRunning == true {
            return "リリース準備の run が実行中です。終わってから確定してください"
        }
        if languages.isEmpty {
            return "AppStore/languages.json に言語がありません"
        }
        if let language = languages.first(where: { problem(for: $0) != nil }), let problem = problem(for: language) {
            return "\(language) の最新情報が\(problem)"
        }
        return nil
    }

    /// 読み直せなかった・最新情報を読めなかった・読めない下書きのときの理由
    private func readingBlockingReason(_ progress: ReleaseProgress) -> String? {
        if readFailure != nil {
            // 前に読んだ状態のまま送ると、そのあいだに変わった run や下書きを見落とす
            return "リリースの状態を読み直せませんでした。更新してからもう一度確定してください"
        }
        switch progress.notes {
        case .failed(let message):
            return message

        case .loaded(let notes):
            if case .unsupportedDraft(let schemaVersion) = notes.status {
                return "下書きの形（schemaVersion \(schemaVersion)）に、このアプリは対応していません。アプリを新しくしてください"
            }
            return nil
        }
    }

    private func workflowBlockingReason(_ workflow: ReleaseProgress.WorkflowState) -> String? {
        if let failure = workflow.failure {
            return failure
        }
        switch workflow.availability {
        case .notFound:
            return "このリポジトリには最新情報の確定のワークフロー（\(ReleaseWorkflow.notes.file)）がありません"

        case .disabled(let state):
            return "最新情報の確定のワークフローは無効にされています（\(state)）。GitHub のリポジトリの Actions で有効にしてください"

        case .active:
            return nil
        }
    }

    func canConfirm(now: Date = .now) -> Bool {
        !isConfirming && !isReading && blockingReason(now: now) == nil
    }

    // MARK: - 確定

    /// 最新情報の確定のワークフローを release ブランチで起動する（inputs は `version` と `whats_new`）。
    /// 起動したら「起動した」状態にして、少し後にリリースの状態を読み直す
    func confirm(now: Date = .now) async {
        guard !isConfirming else {
            return
        }
        guard canConfirm(now: now), let repository, let version else {
            let reason = isReading ? "リリースの状態を読み直しています。読み終わってからもう一度確定してください" : blockingReason(now: now)
            showNotSent(reason)
            return
        }
        let whatsNew = Dictionary(uniqueKeysWithValues: languages.map { ($0, Self.trimmed(texts[$0] ?? "")) })
        isConfirming = true
        errorMessage = nil
        errorIsNotSentReason = false
        defer { isConfirming = false }
        let previousRunID: Int?
        do {
            guard let token = try tokenStore.load() else {
                throw IdeaRequestModel.MissingTokenError()
            }
            let workflow = makeWorkflow(token, ReleaseWorkflow.notes.file)
            // 最後に読んだ状態からは取らない（そのあいだに別の run が始まって終わると取り違える）。送る直前に読み直す
            let latest = try? await ReleaseProgress.latestRun(workflow, repository: repository, version: version)
            guard repository == self.repository, version == self.version else {
                return
            }
            if latest?.isRunning == true {
                showNotSent("最新情報の確定の run が実行中です。終わってから確定してください")
                return
            }
            previousRunID = latest?.id ?? progress?.notesWorkflow.run?.id
            try await workflow.dispatch(
                repository: repository,
                ref: version.branchName,
                inputs: ReleaseWorkflow.notesInputs(version: version, whatsNew: whatsNew)
            )
        } catch {
            if repository == self.repository, version == self.version {
                errorMessage = Self.message(for: error, version: version)
            }
            return
        }
        dispatched["\(repository) \(version)"] = Dispatch(date: now, previousRunID: previousRunID)
        if repository == self.repository, version == self.version {
            // 入力中の本文を送った本文（前後の空白を外したもの）にそろえる。確定が反映されて読んだ本文と同じになれば「直した」扱いも終わる
            texts.merge(whatsNew) { _, sent in sent }
        }
        // dispatch は run の id を返さず、直後の一覧にはまだ出ないので、少し待ってから読み直す
        Task { [weak self, dispatchRefreshDelay] in
            try? await Task.sleep(for: dispatchRefreshDelay)
            await self?.onNeedsRefresh?()
        }
    }

    private func showNotSent(_ reason: String?) {
        errorMessage = "最新情報を確定しませんでした。" + (reason ?? "")
        errorIsNotSentReason = true
    }

    private func clearDispatchedIfRunStarted() {
        guard let key = dispatchKey, let dispatch = dispatched[key], let run = progress?.notesWorkflow.run else {
            return
        }
        if dispatch.previousRunID.map({ run.id > $0 }) ?? true {
            dispatched[key] = nil
        }
    }

    /// 起動の失敗の説明。トークンの値は含めない
    static func message(for error: any Error, version: ReleaseVersion) -> String {
        switch error {
        case is IdeaRequestModel.MissingTokenError:
            return "トークンが未設定です。設定で保存してください"

        case let error as WorkflowError:
            return ReleaseWorkflow.notes.dispatchFailureMessage(error, ref: version.branchName)

        case let error as EncodingError:
            return "最新情報を JSON にできませんでした（\(error.localizedDescription)）"

        default:
            return IdeaRequestModel.message(for: error)
        }
    }
}
