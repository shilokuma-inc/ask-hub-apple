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
- 別の worktree で checkout 中のブランチの PR を `gh pr merge --delete-branch` すると、ローカルのブランチと一緒にその worktree のディレクトリまで消えることがある。
  先に `git -C <worktree> checkout --detach` しておくと消えない
- 検索クエリの `org:a org:b` は OR になる（Issue でも Discussion でも件数がそれぞれの合計になる）。organization が増えても検索は 1 回で済む。
  修飾子を 1 つも付けないと GitHub 全体を検索するので、organization が空なら検索しない

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
- 「Mac Development」の署名用証明書が無い Mac では、macOS 向けの `xcodebuild build` / `test` が署名エラーで止まる。
  CI（`_build.yml`）と同じく、build は `CODE_SIGNING_ALLOWED=NO`、test は `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ENABLE_APP_SANDBOX=NO` を付ける
- `xcode-select` が CommandLineTools を指している Mac では、`swiftlint` が `sourcekitdInProc` を見つけられず Fatal error で落ちる。
  `xcodebuild` と同じく `DEVELOPER_DIR` を Xcode.app に向けて実行する
- UI テストで `app.textFields["placeholder"]` で引いた入力欄は、文字を入力すると placeholder が消えて引けなくなる
  （`value` を読むと No matches found で落ちる）。入力後は `NSPredicate(format: "value CONTAINS %@", …)` で値から探す
- 複数の worktree で同時に iOS の UI テストを流すときは、Simulator も worktree ごとに分ける（同じ Simulator を取り合うと不安定になる）
- サンプルデータ（`-AskHubSampleInbox`）でも、設定の画面（`SettingsView`）は Simulator の Keychain を読み書きする。
  UI テストで「保存」を押すと Simulator にトークンが残るので、押せること（`isHittable`）だけを確かめる
- iOS の `TabView` の `.badge(_:)` の件数は、UI テストからタブのボタン（`app.tabBars.buttons["…"]`）の `value` にも `label` にも出ない。
  バッジの件数は UI テストのアサーションでは確かめられないので、サンプルデータのスクリーンショットで確かめる
- `AskHubUITestsLaunchTests`（`runsForEachTargetApplicationUIConfiguration`）は横向きでも起動するので、Simulator が横向きのまま残り、
  続けて流す UI テストが要素を見つけられず一斉に落ちることがある（ログに `Interface orientation changed to Landscape Left` が出る）。
  UI テストの `setUp` で `XCUIDevice.shared.orientation = .portrait` に戻す（`orientation` は iOS にしか無いので `#if os(iOS)` で囲む。CI は macOS でも UI テストをビルドする）
- 画面収録・アクセシビリティ（オートメーション）の許可が無い Mac では、macOS の UI テストは
  「Timed out while enabling automation mode」で起動できず、`screencapture -l <ウィンドウ ID>` も「could not create image from window」で失敗する。
  その場合でも、macOS のユニットテスト（`AskHubTests`。sandbox なしで流す）の中で View を `NSHostingView` に載せて `NSWindow` に置き、
  `orderFrontRegardless()` で少し待ってから `bitmapImageRepForCachingDisplay(in:)` / `cacheDisplay(in:to:)` で描けば、`List` を含めて許可なしで PNG にできる。
  `NSAppearance(named: .aqua / .darkAqua)` を window と hosting view に設定すればライト・ダークを撮り分けられる（撮影用のテストはコミットしない）
- `xcode-select` が CommandLineTools を指している Mac では、`swift test --package-path AskHubKit` もテストのビルド中に
  `sourcekitdInProc` の読み込みで Fatal error になり「Build failed」で止まる。swiftlint と同じく `DEVELOPER_DIR` を Xcode.app に向けて実行する
- iOS の UI テストで `app.keyboards.firstMatch.frame` はキーの部分だけで、`ToolbarItemGroup(placement: .keyboard)` の「完了」の帯はその上に重なる。
  入力欄の中心がこの帯にかかると、`tap()` が帯に当たり「Neither element nor any descendant has keyboard focus」で落ちる。
  `swipeUp()` しても `Form` の中身が画面に収まっていればスクロールしないので、下の入力欄に移る前に `keyboard-done` でキーボードを閉じる
- iOS の `Form` は画面の外の行を作らないので、UI テストで下のほうのボタン（例: 「作成を依頼する」）は `exists` が `false` になる。
  入力欄が切り替わったことは、画面の上にある要素（`template-picker` など）で確かめる。セグメントの `Picker` は `app.segmentedControls["<ID>"].buttons["<文言>"]` で引け、`isSelected` で選択中かが分かる

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
- `AttributedString(markdown:)` はインライン HTML（`<b>` など）を解釈せず文字のまま残し、`&lt;` などの文字参照は自分でデコードする。
  HTML を Markdown に変換してから渡すときは、文字参照をデコードしない（二重デコードになる）。ただし Markdown のコードスパン・
  コードブロックの中では文字参照がそのまま出るので、HTML の `<pre>` / `<code>` の中身だけは変換側でデコードする
- `AttributedString(markdown:)` の `.full` は段落内の 1 つの改行を空白にまとめる（`.inlineOnlyPreservingWhitespace` は残す）。
  改行を確実に残すには、行末に空白 2 つか `\` を置くハードブレークにする
- `AttributedString(markdown:)` の `.full` では、ブロック（段落・見出し・リストの項目・コードブロック）の間に改行の文字が入らず、
  `presentationIntent` の `components` の identity だけで区切りが分かる。描画用に分けるときは run を identity でまとめる。
  入れ子のリストは `listItem` と `unorderedList` / `orderedList` が内側から外側の順に並び、ハードブレークは `inlinePresentationIntent` が
  `.lineBreak` の `"\n"` の run になる
- `JSONEncoder` は文字列の中の `>` をエスケープしない（`/` は `.withoutEscapingSlashes` を付けなければ `\/` になる）。
  JSON を HTML コメント（`<!-- … -->`）に埋めるときは、エンコード後に `>` を `\u003e` に置き換えると、値に `-->` があっても目印が途中で閉じない。
  `.iso8601` の日付は秒未満を落とすので、読み戻した値と `==` で比べるなら書き出す前に秒未満を切り捨てる
- アプリのターゲットは MainActor 既定なので、`InboxModel.org` のようなモデルの `static let` も MainActor に隔離される。
  `Sendable` なプロトコル（`LoopStatusSource` など）に準拠するサンプルの型で `private static let org = InboxModel.org` と書くと、
  「main actor-isolated default value in a nonisolated context」になる。メソッドの引数（`org`）を使うか、文字列を直接書く

## シェルスクリプト

- bash で `"$CONFIG（…）"` のように変数の直後に全角文字を書くと、バイト単位で変数名の一部と読まれ、`set -u` で unbound variable になる。
  日本語が続く変数は `${CONFIG}` と波かっこで囲む
- launchd の LaunchAgent は既定でジョブの終了時にプロセスグループごと止める。子プロセス（ループなど）を残したいときは `AbandonProcessGroup` を `true` にする
- zsh では `$C:refs/...` のように変数の直後に `:r` などが続くと修飾子（拡張子の除去など）として解釈される。`git push origin "${C}:refs/heads/…"` のように波かっこで囲む
- `git status --porcelain` は、中身がすべて未追跡のディレクトリを `?? .claude/` のように 1 行にまとめる。ファイル名で除外したいときは `--untracked-files=all` を付ける
- `git remote get-url origin` は `url.<base>.insteadOf` で書き換えた後の URL を返す。設定に書かれた URL と比べるときは `git config --get remote.origin.url` を使う
- squash merge 済みのブランチは、コミットがどのリモートにも無いので「未 push」に見える。`git merge-tree --write-tree <既定ブランチ> <ブランチ>` の木が既定ブランチの木（`<既定ブランチ>^{tree}`）と同じなら、取り込んでも何も変わらない（変更はすべて既定ブランチにある）と判定できる（git 2.38 以降）

## SwiftUI

- `List` の行を `Link` で包むと、行の中の文字がすべてアクセントカラーになり `.foregroundStyle(.secondary)` も効かない。
  `Link` に `.buttonStyle(.plain)` を付け、行に `.frame(maxWidth: .infinity, alignment: .leading)` と `.contentShape(.rect)` を付けて行全体をタップできるようにする
- 一覧などの UI をテストやスクリーンショットで確かめるときは、DEBUG ビルドだけの起動引数（`-AskHubSampleInbox`）でサンプルデータに切り替える。
  Preview と同じサンプルを使い回せ、GitHub にもトークンにも依存しない
- `ToolbarItemGroup(placement: .keyboard)` は Deployment Target が macOS 14 でもビルドエラーにならない（`#if os(iOS)` で囲まなくてよい）。
  同じ画面で重複して出ないよう、入力欄ごとではなく `Form` に 1 回だけ付ける
- `Form` の `Section` 群を別の View に切り出して他の `Form` に埋め込むときは、`.keyboardDoneButton` を付ける埋め込み先と同じフォーカスを使うため、
  `@FocusState` は埋め込み先で持ち、切り出した View には `FocusState<Bool>.Binding` で渡す（`.focused(isEditing)`、閉じるときは `isEditing.wrappedValue = false`）。
  切り出した View の `body` は `Group { Section … }` にすると、`.onAppear` などの修飾子を `Section` 群にまとめて付けられる
- `.background(.bar)` のような `ShapeStyle` の背景は既定で safe area まで広がるため、`safeAreaInset(edge: .top)` の帯に付けると iOS の大きいタイトルを覆ってぼかす。
  帯の中だけに付けるときは `.background(.bar, ignoresSafeAreaEdges: [])` にする
