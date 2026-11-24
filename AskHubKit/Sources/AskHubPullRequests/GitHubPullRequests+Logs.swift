import Foundation

extension GitHubPullRequests {
    /// 読むログの長さの上限（バイト）。落ちた理由は後ろに出るので、超えた分は前を捨てる
    public static let maximumLogBytes = 256 * 1024
    /// 先頭から読むログの長さの上限（バイト）。xcodebuild の引数とビルドの設定は Archive の始めに出るので、後ろは読まない
    public static let maximumLogHeadBytes = 4 * 1024 * 1024

    /// GitHub Actions の job のログ（`FailedCheck.jobID`）。長いログは末尾の `maximumLogBytes` だけを返す。
    ///
    /// API は短い間だけ使える署名つきの URL へリダイレクトするので、その先はトークンを付けずに取る
    public func jobLog(jobID: Int) async throws(PullRequestError) -> String {
        try GitNames.checkNumber(jobID)
        // 大きいログを丸ごと取らないよう、末尾だけを頼む
        let data = try await api.download("actions/jobs/\(jobID)/logs", range: .tail(Self.maximumLogBytes))
        var tail = data.suffix(Self.maximumLogBytes)
        // 切った所が文字の途中なら、続きのバイト（10xxxxxx）を捨てる
        while let first = tail.first, first & 0xC0 == 0x80 {
            tail = tail.dropFirst()
        }
        // UTF-8 で読めないログ（壊れたバイトを含む）は、1 バイトずつの文字として読む
        return String(bytes: tail, encoding: .utf8) ?? String(bytes: tail, encoding: .isoLatin1) ?? ""
    }

    /// GitHub Actions の job のログの先頭の `maximumLogHeadBytes` だけ（配信したビルドを上げた Upload の実行を、ビルドの番号で確かめる）
    public func jobLogHead(jobID: Int) async throws(PullRequestError) -> String {
        try GitNames.checkNumber(jobID)
        let data = try await api.download("actions/jobs/\(jobID)/logs", range: .head(Self.maximumLogHeadBytes))
        let head = data.prefix(Self.maximumLogHeadBytes)
        // 切った所が文字の途中で UTF-8 で読めなければ、1 バイトずつの文字として読む（探すのは ASCII の語なので変わらない）
        return String(bytes: head, encoding: .utf8) ?? String(bytes: head, encoding: .isoLatin1) ?? ""
    }
}
