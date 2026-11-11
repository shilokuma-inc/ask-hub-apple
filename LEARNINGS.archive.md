# LEARNINGS（退避）

`LEARNINGS.md` から外した項目。使わなくなった仕組みのもので、消さずに残す。

## 今の仕組み（オーケストレーター・ralph-loop）の項目（2026-11-11 に退避。#970 で新しい AskHub に切り替え、#976 で今の仕組みを外したため）

### GitHub

- リポジトリごとのラベル（`askhub-orchestrator` の担当の印など）を org 全体で読むときは、GraphQL の
  `organization.repositories(first: 100, after: $after, isArchived: false) { pageInfo { hasNextPage endCursor } nodes { nameWithOwner label(name:) { description } } }`
  を使い、`hasNextPage` が `false` になるまで `after` に `endCursor` を渡して取り直す（connection は `first` / `last` が必須で 1〜100 件）。
  Search API ではないので 30 回/分の制限も検索インデックスによる件数のずれも無い

### ビルド・テスト

- `AskHubKit` の public な型の名前を変えた直後の `swift test --package-path AskHubKit` は、別のターゲット（`OrchestratorKitTests` など）の古いオブジェクトが残り、
  「Undefined symbols」（古い型名の `init`）でリンクが落ちることがある。コードの誤りではないので、`AskHubKit/.build` を消してビルドし直す
- ralph-loop の xcodebuild のラッパー（別の Mac で実行する）で UI テストを流すと、`.xcresult` は実行した Mac に残り、ログの末尾にそのパスが出る。
  `-resultBundlePath` で手元に書かせることはできないので、スクリーンショットはそのパスを `rsync` で取り寄せてから `xcrun xcresulttool export attachments` で取り出す

### シェルスクリプト

- ralph-kit の `install.sh <checkout>` は中継のファイルを置き、CLAUDE.md の ralph-kit:snippet の目印の間を書き換えるだけで、CLAUDE.md に「## ralph-loop による自律開発」の節が無いときは
  案内を表示して終了コード 0 で終わる（節は足さない。コミットもしない）。節の無いリポジトリに入れるときは、先に kit の `templates/CLAUDE.snippet.md` の見出しから end の目印までを足してから流す（`add-repo.sh`）
