import Foundation

extension GitHubPullRequests {
    /// 読むログの長さの上限（バイト）。落ちた理由は後ろに出るので、超えた分は前を捨てる
    public static let maximumLogBytes = 256 * 1024

    /// GitHub Actions の job のログ（`FailedCheck.jobID`）。長いログは末尾の `maximumLogBytes` だけを返す。
    ///
    /// API は短い間だけ使える署名つきの URL へリダイレクトするので、その先はトークンを付けずに取る
    public func jobLog(jobID: Int) async throws(PullRequestError) -> String {
        try GitNames.checkNumber(jobID)
        let data = try await api.download("actions/jobs/\(jobID)/logs")
        var tail = data.suffix(Self.maximumLogBytes)
        // 切った所が文字の途中なら、続きのバイト（10xxxxxx）を捨てる
        while let first = tail.first, first & 0xC0 == 0x80 {
            tail = tail.dropFirst()
        }
        // UTF-8 で読めないログ（壊れたバイトを含む）は、1 バイトずつの文字として読む
        return String(bytes: tail, encoding: .utf8) ?? String(bytes: tail, encoding: .isoLatin1) ?? ""
    }
}
