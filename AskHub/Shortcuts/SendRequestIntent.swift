import AppIntents

/// Siri・ショートカットから依頼を送る（Issue #1122）。アプリの「新しい依頼」と同じ依頼の意図を、この端末の鍵で署名して状態リポジトリに置く。
///
/// - 送る前に確認しない。アプリは開かない。送れたかどうかは、Siri とショートカットのアプリに文で返す
/// - この端末の鍵はロックの解除中だけ使えるので、ロック中はシステムに解除させてから動かす（`docs/renewal/security.md` の「鍵」）
struct SendRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "依頼を送る"
    static let description = IntentDescription("選んだリポジトリに依頼を送ります。1 行目が要約（epic の名前）、2 行目からが依頼の内容になります。送る前の確認はありません")
    static let openAppWhenRun = false
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    // Siri はこの順（依頼先 → 依頼の文）に聞く
    @Parameter(title: "依頼先", requestValueDialog: "どのリポジトリに依頼しますか？")
    var repository: RequestRepositoryEntity

    @Parameter(title: "依頼の文", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "どんな依頼ですか？")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$repository) に \(\.$text) を依頼")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let request = ShortcutRequestText(text) else {
            throw $text.needsValueError("どんな依頼ですか？")
        }
        let sent = try await ShortcutRequests().send(request, to: repository.id)
        return .result(dialog: "\(sent.message)")
    }
}
