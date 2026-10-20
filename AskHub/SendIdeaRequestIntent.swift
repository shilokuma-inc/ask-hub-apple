import AppIntents
import AskHubKit
import Foundation

/// Siri・ショートカットから「機能追加・修正」の依頼（`idea-request` の Issue）を送る（Discussion #655）。
/// 送る前に確認しない（Q3）。ロック中は解除してから送る（Q4）。アプリは開かない
struct SendIdeaRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "機能追加・修正を依頼"
    static let description = IntentDescription("選んだリポジトリに、機能追加・修正の依頼（Issue）を送ります。送る前の確認はありません")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    // Siri はこの順（依頼先 → 要約 → 依頼文）に聞く。要約と依頼文は別々に聞く（Q2）
    @Parameter(title: "依頼先", requestValueDialog: "どのリポジトリに依頼しますか？")
    var repository: RepositoryEntity

    @Parameter(title: "要約", requestValueDialog: "依頼の要約を 1 行で教えてください")
    var summary: String

    @Parameter(
        title: "依頼文",
        inputOptions: String.IntentInputOptions(multiline: true),
        requestValueDialog: "依頼の内容を教えてください"
    )
    var body: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$repository) に「\(\.$summary)」を依頼") {
            \.$body
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        do {
            let sent = try await IdeaRequestSubmission().send(repository: repository.id, summary: summary, body: body)
            return .result(value: sent.url, dialog: "\(sent.message)")
        } catch IdeaRequestInputError.summary {
            throw $summary.needsValueError("要約を 1 行で教えてください")
        } catch IdeaRequestInputError.body {
            throw $body.needsValueError("依頼の内容を教えてください")
        }
    }
}

/// 要約・依頼文が送れない形（Siri はその値を聞き直す）
enum IdeaRequestInputError: Error, Equatable {
    /// 要約が空か、改行を含む
    case summary
    /// 依頼文が空
    case body
}

/// Siri・ショートカットから送った依頼
struct IntentSentRequest: Equatable {
    /// 作った Issue の URL（ショートカットで次のアクションに渡せる）
    let url: URL
    /// Siri のダイアログ。例: `ask-hub-apple に「通知の頻度を調整したい」を依頼しました`
    let message: String
}

/// Siri・ショートカットから依頼を送る処理（トークンの読み込み → 入力の検査 → Issue の作成 → 結果の文言）。テストでは requester を差し替える
struct IdeaRequestSubmission {
    var requesters = IntentRequesterSource()

    /// 依頼の Issue を作る。要約・依頼文が送れない形なら `IdeaRequestInputError`、それ以外の失敗は `AppIntentError`（アプリと同じ文言）
    func send(repository: String, summary: String, body: String) async throws -> IntentSentRequest {
        let request = IdeaRequest(repository: repository, summary: summary, body: body)
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSummary.isEmpty || trimmedSummary.contains(where: \.isNewline) {
            throw IdeaRequestInputError.summary
        }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw IdeaRequestInputError.body
        }
        do {
            guard request.isValid, RepositoryName.isValidFullName(repository) else {
                throw IdeaRequestError.invalidRequest
            }
            let isSample = requesters.usesSampleData()
            let issue = try await requesters.requester().create(request)
            let sent = SentRequest(request: request, issue: issue)
            // デモモードでは GitHub に書き込まないので、送っていないことを添える
            let message = isSample ? sent.message + "（デモモードのため、GitHub には送っていません）" : sent.message
            return IntentSentRequest(url: issue.htmlURL, message: message)
        } catch {
            throw AppIntentError.wrapping(error)
        }
    }
}
