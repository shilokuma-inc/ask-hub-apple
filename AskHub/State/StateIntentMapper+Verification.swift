import AskHubClient
import AskHubProtocol
import Foundation

// MARK: - 実機確認

extension StateIntentMapper {
    /// マージした後の操作を送れるか。リリース文の公開は下書きがあってまだ公開していない版だけ、プロモーションテキストは配信中の版だけ、
    /// 実機確認への答えはマージした epic の、まだ答えていない項目だけ。まとめての答えは、答えていない項目が残っている epic だけ
    func supportsAfterMerge(_ intent: HumanIntent) -> Bool {
        switch intent {
        case let .publishRelease(repositoryID, version, _, _):
            index.releases[Release.id(repositoryID, version)]?.canPublish == true

        case let .updatePromotionalText(repositoryID, version, _):
            index.promotionalTexts[Release.id(repositoryID, version)]?.canUpdate == true

        case let .verify(epicID, itemID, _):
            index.epics[epicID]?.verification?.unanswered.contains(itemID) == true

        case .closeVerifications(let epicID, _):
            index.epics[epicID]?.verification?.unanswered.isEmpty == false

        default:
            false
        }
    }

    /// 実機確認への答え。確かめたゴールの版に結びつける。「問題あり」は、確かめた項目・元の epic・最終 PR を添えた依頼も一緒に送り、
    /// 新しい epic で直してもらう（司令塔は答えを記録するだけ）。「このリリースで直す」なら、依頼に直すリリースの版を付ける
    func verifyDrafts(
        epicID: Epic.ID,
        itemID: VerificationItem.ID,
        reply: VerificationReply
    ) throws(ClientServiceError) -> [IntentDraft] {
        let epic = try epic(epicID)
        guard let verification = epic.verification, verification.items[itemID] != nil else {
            throw Self.notAnswerable
        }
        let target = VerificationTarget(repo: epic.repo, epic: epic.id, item: itemID, goalVersion: verification.goalVersion)
        let problem = try Self.problemNote(reply)
        let release = try Self.problemRelease(reply)
        let request = problem.map {
            Self.problemRequest(repo: epic.repo, item: itemID, note: $0, verification: verification, release: release)
        }
        guard verification.unanswered.contains(itemID) else {
            // 「問題あり」の答えだけが届き、依頼を送れなかったときの送り直し（同じ説明の「問題あり」だけ）。
            // 答えがまだ処理を待っていれば、送る処理（`perform`）が送ってある答えを除いて依頼だけを送る。記録された後なら依頼だけを作る
            guard let problem, let request, verification.problemNotes[itemID] == problem else {
                throw Self.notAnswerable
            }
            return verification.pendingAnswers.contains(itemID) ? [.verify(target, result: .problem, note: problem), request] : [request]
        }
        guard let problem, let request else {
            return [.verify(target, result: .confirmed)]
        }
        return [.verify(target, result: .problem, note: problem), request]
    }

    /// 実機確認のまとめての答え（「まとめて確認した」「確かめずに閉じる」）。確かめたゴールの版に結びつける。
    /// 司令塔は、受け取った時点でまだ答えていない項目すべてに付けるので、項目の id は送らない。確かめずに閉じた理由は空でもよい
    func closeVerificationsDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        guard case let .closeVerifications(epicID, reply) = intent else {
            throw Self.unsupported
        }
        let epic = try epic(epicID)
        guard let verification = epic.verification, !verification.unanswered.isEmpty else {
            throw ClientServiceError(message: "この epic には、答えていない実機確認がありません（もう答えたか、マージした epic でない）。取り直してください")
        }
        let target = EpicTarget(repo: epic.repo, epic: epic.id, version: verification.goalVersion)
        guard case .skipped(let note) = reply else {
            return .closeVerifications(target, result: .confirmed)
        }
        let reason = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // 司令塔（`PayloadReader`）と同じく、Unicode のコードポイントで数える
        guard reason.unicodeScalars.count <= CloseVerificationsIntent.maximumNoteLength else {
            throw ClientServiceError(message: "閉じる理由は \(CloseVerificationsIntent.maximumNoteLength) 文字までにしてください")
        }
        return .closeVerifications(target, result: .skipped, note: reason)
    }

    private static let notAnswerable = ClientServiceError(message: "この項目には、いまは答えられません（もう答えたか、マージした epic でない）。取り直してください")

    /// 「問題あり」の説明（前後の空白を除く）。「確認した」は nil
    private static func problemNote(_ reply: VerificationReply) throws(ClientServiceError) -> String? {
        guard case .problem(let note, _) = reply else {
            return nil
        }
        let problem = note.trimmingCharacters(in: .whitespacesAndNewlines)
        // 司令塔（`PayloadReader`）と同じく、Unicode のコードポイントで数える
        guard !problem.isEmpty, problem.unicodeScalars.count <= VerifyIntent.maximumNoteLength else {
            throw ClientServiceError(message: "何が起きたかを 1〜\(VerifyIntent.maximumNoteLength) 文字で書いてください")
        }
        return problem
    }

    /// 「このリリースで直す」の直すリリースの版。次のリリースで直すなら nil
    private static func problemRelease(_ reply: VerificationReply) throws(ClientServiceError) -> MarketingVersion? {
        guard case .problem(_, let release?) = reply else {
            return nil
        }
        guard let version = MarketingVersion(rawValue: release) else {
            throw ClientServiceError(message: "直すリリースの版の形が違います")
        }
        return version
    }

    /// 「問題あり」から作る依頼。要約は確かめたこと、内容は元の epic・最終 PR・何が起きたか。
    /// `release` があれば「このリリースを直す」依頼にする（epic はその版の release ブランチを base にする）
    static func problemRequest(
        repo: RepositoryFullName,
        item: String,
        note: String,
        verification: StateIndex.VerificationEntry,
        release: MarketingVersion? = nil
    ) -> IntentDraft {
        let checked = verification.items[item] ?? item
        let title = clipped("実機確認で問題: \(checked)", to: RequestIntent.maximumTitleLength)
        let target = release.map { "\n\nリリース \($0.rawValue) の中で直す（release ブランチ release/\($0.rawValue) に向ける）。" } ?? ""
        let body = """
            epic「\(verification.title)」（最終 PR #\(verification.pullRequest)）の実機確認で、問題がありました。\(target)

            確かめたこと（\(item)）: \(checked)

            何が起きたか:
            \(note)
            """
        return .request(repo: repo, title: title, body: clipped(body, to: RequestIntent.maximumBodyLength), release: release)
    }

    /// Unicode のコードポイントで `limit` までに切る（司令塔は意図の文の長さをコードポイントで数える）
    private static func clipped(_ text: String, to limit: Int) -> String {
        guard text.unicodeScalars.count > limit else {
            return text
        }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(limit - 1))
        return String(scalars) + "…"
    }
}
