# LEARNINGS

このリポジトリで開発して分かった知見（ハマりどころ・API の癖・ツールの挙動）を残す。
次に作業する人やループ（Claude）が同じ所で詰まらないためのメモ。

## 書き方

- 1 項目 = 1 つの知見。見出しの下に箇条書きで追記する。**既存の行は書き換えず、末尾に足す**
  （`.gitattributes` で `merge=union` にしている。これが効くのは**ローカルの git でのマージ・リベース**だけで、
  GitHub 上の PR のマージには効かない。並行する PR が同じ箇所に追記して GitHub がコンフリクトと判定したら、
  ローカルで `git merge origin/<base>`（またはリベース）すると両方の追記が自動で残る）
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
- 検索クエリの `label:a,b` はカンマ区切りで OR になる（`label:a label:b` は AND）。複数のラベルの Issue を 1 回の検索で取れる
- GitHub 上のマージ（`gh pr merge` や PR の画面）は `.gitattributes` の `merge=union` を使わない。並行する PR が同じ箇所に追記すると、
  GitHub ではコンフリクトになる。ローカルで統合ブランチに rebase すれば union で自動解消されるので、検証してから `--force-with-lease` で push する
- `gh pr merge` が失敗しても後続のコマンドは続いてしまう。Issue のクローズなどは、PR の state が `MERGED` になったのを確かめてから行う
- リポジトリごとのラベル（`askhub-orchestrator` の担当の印など）を org 全体で読むときは、GraphQL の
  `organization.repositories(first: 100, after: $after, isArchived: false) { pageInfo { hasNextPage endCursor } nodes { nameWithOwner label(name:) { description } } }`
  を使い、`hasNextPage` が `false` になるまで `after` に `endCursor` を渡して取り直す（connection は `first` / `last` が必須で 1〜100 件）。
  Search API ではないので 30 回/分の制限も検索インデックスによる件数のずれも無い

## ビルド・テスト

- Simulator は OS 更新で `iPhone 17 Pro (6.3inch/1206x2622)` のように改名されることがある。
  名前で解決できないときは `xcrun simctl list devices available` で UDID を調べて `id=` で指定する
- 複数の worktree で同時に `xcodebuild` を流すときは、`-derivedDataPath` を worktree ごとに分ける。
  同じ DerivedData を共有するとビルドが壊れる
- Icon Composer の `.icon`（`AskHub/AppIcon.icon`）は `PBXFileSystemSynchronizedRootGroup` のフォルダに置くだけでターゲットに入り、
  `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` のまま拾われる（pbxproj・xcconfig の変更は不要）。
  同名の `AppIcon.appiconset` が残っていても `.icon` が優先されるが、紛らわしいので `.appiconset` は削除した
- `.icon` は Deployment Target が iOS 17 / macOS 14 でもビルドでき、旧 OS 向けのフォールバックが自動で生成される。
  iOS は `AppIcon60x60@2x.png` / `AppIcon76x76@2x~ipad.png` と `Assets.car`（ライト・ダーク・ティント）、
  macOS は `Contents/Resources/AppIcon.icns`（`CFBundleIconFile`）と `Assets.car`。フォールバックの PNG にはガラスの質感が焼き込まれる
- `.icon` の中身は `icon.json`（背景の `fill`・`groups` → `layers` の `image-name`。`layers` は先頭が最前面）と `Assets/` の SVG / PNG。
  SVG はテキストで書けるので差分をレビューしやすい。`stroke` の線もそのまま描画される
- "Mac Development" の署名用証明書が無い環境では、macOS の `xcodebuild build` は `CODE_SIGNING_ALLOWED=NO`、
  `xcodebuild test` は `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`（アドホック署名）で通る
- CI（`_build.yml`）の Xcode 26.3 でも `.icon` はそのままビルド・テストが通る（CI の Xcode を上げる必要は無かった）
- macOS の UI テストのランナーは sandbox の中で動くので、`/tmp` などにファイルを書けない（iOS Simulator では書ける）。
  スクリーンショットは `XCTAttachment`（`lifetime = .keepAlways`）で残し、`xcrun xcresulttool export attachments` で取り出す。
  画面全体が写るので、PR に載せる前にアプリのウィンドウだけ切り抜く
- SwiftUI の `Picker` の中に `Section("見出し")` を置くと、iOS / macOS ともメニューに見出し付きの区切りとして出る

## Keychain

- macOS で `kSecUseDataProtectionKeychain` を使うには、provisioning profile で許可された entitlement
  （`keychain-access-groups` / `application-identifier`）付きの署名が要る（TN3137）。無いと `errSecMissingEntitlement`（-34018）になる。
  付けない場合は従来の Keychain になり、`kSecAttrAccessible`（`AfterFirstUnlock` など）は効かない

## Swift

- Swift 6 の Strict Concurrency では `Regex` が `Sendable` ではないため、`private static let pattern = /…/` は
  「not concurrency-safe」のエラーになる。`static var pattern: Regex<…> { /…/ }` のように computed property にする
- macOS の一時ディレクトリ（`/var/folders/…`）は `/private/var` へのシンボリックリンクを含む。
  `URL.resolvingSymlinksInPath()` は `/private` を外した形を返すため、`pwd -P` の結果などと比べるときは `realpath(3)` を使う
- `Process` で起動した子プロセスの生存は、`Process` を保持しておいて `isRunning` で見る。
  `Process` は `Sendable` ではないので、`actor` の状態として持つと `@unchecked Sendable` なしで扱える

## シェルスクリプト

- bash で `"$CONFIG（…）"` のように変数の直後に全角文字を書くと、バイト単位で変数名の一部と読まれ、`set -u` で unbound variable になる。
  日本語が続く変数は `${CONFIG}` と波かっこで囲む
- launchd の LaunchAgent は既定でジョブの終了時にプロセスグループごと止める。子プロセス（ループなど）を残したいときは `AbandonProcessGroup` を `true` にする

## SwiftUI

- `List` の行を `Link` で包むと、行の中の文字がすべてアクセントカラーになり `.foregroundStyle(.secondary)` も効かない。
  `Link` に `.buttonStyle(.plain)` を付け、行に `.frame(maxWidth: .infinity, alignment: .leading)` と `.contentShape(.rect)` を付けて行全体をタップできるようにする
- 一覧などの UI をテストやスクリーンショットで確かめるときは、DEBUG ビルドだけの起動引数（`-AskHubSampleInbox`）でサンプルデータに切り替える。
  Preview と同じサンプルを使い回せ、GitHub にもトークンにも依存しない
