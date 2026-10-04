# LEARNINGS

このリポジトリで開発して分かった知見（ハマりどころ・API の癖・ツールの挙動）を残す。
次に作業する人やループ（Claude）が同じ所で詰まらないためのメモ。

## 書き方

- 1 項目 = 1 つの知見。見出しの下に箇条書きで追記する。**既存の行は書き換えず、末尾に足す**
  （`.gitattributes` で `merge=union` にしているので、並行する PR の追記は衝突せずに両方残る）
- 「何が起きたか」と「どうすればよいか」をセットで書く
- **PC 固有の値（ローカルパス・Simulator の UDID・ユーザー名など）は書かない**。PC ごとの設定に置く
- 実装 PR の中で追記してよい（知見のためだけの PR を分けなくてよい）

## GitHub

- 統合ブランチ（`epic/**`）宛ての PR では、本文の `resolve #N` による Issue の自動クローズが効かない。
  自動クローズはデフォルトブランチへのマージでしか発火しないため、マージ後に `gh issue close` で明示的に閉じる
- Search API のレート制限は認証済みでもエンドポイントにより異なる（コード検索は 10 回/分、それ以外の検索は 30 回/分）。
  REST の通常の上限より厳しいので、ポーリングで検索を多用しない
- GraphQL の `search` の `nodes` は、`... on Discussion` などのフラグメントに合わない型のノードを `{}` で返す。
  フィールドを optional でデコードし、必要な値が揃ったノードだけを使う
- PR のレビュースレッド（GraphQL の `reviewThreads`）は、最初のコメントがスレッドの起点で、2 件目以降が返信にあたる。
  コメントの `databaseId` は REST のコメント id と同じなので、`pulls/{n}/comments/{id}/replies` での返信に使える

## ビルド・テスト

- Simulator は OS 更新で `iPhone 17 Pro (6.3inch/1206x2622)` のように改名されることがある。
  名前で解決できないときは `xcrun simctl list devices available` で UDID を調べて `id=` で指定する
- 複数の worktree で同時に `xcodebuild` を流すときは、`-derivedDataPath` を worktree ごとに分ける。
  同じ DerivedData を共有するとビルドが壊れる

## Keychain

- macOS で `kSecUseDataProtectionKeychain` を使うには、provisioning profile で許可された entitlement
  （`keychain-access-groups` / `application-identifier`）付きの署名が要る（TN3137）。無いと `errSecMissingEntitlement`（-34018）になる。
  付けない場合は従来の Keychain になり、`kSecAttrAccessible`（`AfterFirstUnlock` など）は効かない
