import AskHubKit

extension Answer {
    /// 投稿する返信の 1 行目（`回答: <選んだ選択肢>`）。選択肢を選んでいなければ `nil`。
    ///
    /// 投稿前に確かめられるよう画面に出す。接頭辞を直書きせず、投稿する本文と同じ組み立て（`body`）から作る
    var choiceLine: String? {
        guard let choice else {
            return nil
        }
        return Answer(choice: choice).body
    }
}
