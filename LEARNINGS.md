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
- CodeRabbit の無料枠は 1 時間に 1 回のレビューで、上限に当たった PR には「Review rate limited」と出る。上限が戻っても自動ではレビューされないので、
  PR に `@coderabbitai review` とコメントして頼む（1 回で 1 本の PR を使い切る。上限中に push した続きのコミットは、そのまま未レビューで残る）
- `workflow_dispatch`（`POST /repos/{owner}/{repo}/actions/workflows/{file}/dispatches`）は 204 を返すだけで run の id を返さず、直後に `runs?branch=` を読んでも新しい run はまだ一覧に出ない（数秒かかる）。アプリでは「起動した」状態を持ち、少し後に取り直す。
  run の `run_started_at` / `created_at` は秒精度なので、起動時刻（サブ秒）との比較で新旧を判定するときは同じ秒内の run に注意する
- コミットの `statusCheckRollup.contexts` は check run（`CheckRun`。GitHub Actions など）と commit status（`StatusContext`。CodeRabbit など）が混ざった connection。
  `__typename` で見分け、GitHub Actions の check run は `checkSuite.app.slug == "github-actions"` で選ぶ。`CheckRun.conclusion` は実行中なら `null`、
  `StatusContext.description` やアプリが削除された check run の `checkSuite.app` も `null` になり得るので optional で受ける
- 同じコミットに `push` と `pull_request` の両方で同じワークフローが走ると、`statusCheckRollup.contexts` に同名の check run（`build / build`）が 2 件並ぶ。
  名前で 1 件に絞らず、全件を見て「1 つでも失敗なら失敗」で判定する
- CodeRabbit は PR の head のコミットに commit status `CodeRabbit` を付ける。レビュー中は `pending`（"Review in progress"）、完了は `success`（"Review completed"）で、
  無料枠の上限に当たったときも `success`（"Review rate limited"）になる。レート制限かどうかは `description` の文言でしか見分けられない
- コミットの `statusCheckRollup.state` は check run と commit status をまとめた値なので、CodeRabbit が `pending` の間は GitHub Actions が全部成功していても `PENDING` になる。
  GitHub Actions だけで判定したいときは `state` ではなく `contexts` を取り、check run だけを見る
- CodeRabbit がレビューしなかったときも commit status `CodeRabbit` は `success` で、`description` が "Review skipped" か、理由付きの
  "Review skipped: reviews are disabled for this base branch"（`.coderabbit.yaml` で自動レビューの対象外にした base 宛ての PR）になる。完了・レート制限と同じく文言でしか見分けられない
- PR の timeline（GraphQL の `timelineItems`）からは、通常の push の時刻は取れない（取れるのは force push の `HeadRefForcePushedEvent` だけ）。
  head を GitHub が受け取った時刻の目安には、commit status の `createdAt`（CodeRabbit は push を受け取ると付ける）か、コミットの `committedDate`（push より前になりうる）を使う
- bot のアカウントの login は、GraphQL（`author { login }`）では `coderabbitai`、REST（`user.login`）では `coderabbitai[bot]` のように `[bot]` が付く。
  CodeRabbit などの bot を author で見分けるときは、両方の形を受け付ける（`CodeRabbitReviewThread.authorLogins`）
- PR のコメントに CodeRabbit のアカウント名を `@` 付きで書くと、コードスパンの中（`` `@coderabbitai review` ``）でもメンションとして扱われ、CodeRabbit が返信する。
  説明として書くだけなら `@` を付けない
- `gh run view <run> --log-failed` は失敗したジョブのログだけを出すが、run がまだ実行中だと全ジョブのログが揃わない。
  「マージ待ち」の `checks` は失敗が 1 つでもあれば実行中の check run が残っていても `failure` になるので、
  失敗したログで直させる処理は `hasRunningChecks` が `false`（すべて終わった）になってから始める
- 再利用ワークフローの中で、条件付きで飛ばすジョブ（`if:` が偽で skipped）を `needs` にすると、後続のジョブも既定では skipped になる。
  後続を動かすには `if: ${{ !cancelled() && (needs.<id>.result == 'skipped' || needs.<id>.outputs.<名前> == 'true') }}` のように状態の関数を付ける（前のジョブが失敗したときは outputs が空になるので、この条件なら後続は飛ぶ）
- `strategy.matrix.include: ${{ fromJSON(needs.plan.outputs.x) }}` に空の配列（`[]`）を渡すと、ジョブを作れず「Matrix must define at least one vector」で run が失敗する。
  設定によって空になりうる matrix（例: Mac の表示サイズだけを指定したときの撮影）は、前のジョブで `has_x=$(jq -r 'length > 0')` を出し、ジョブの `if:` で飛ばす
- `GET /repos/{owner}/{repo}/git/matching-refs/{ref}` は前方一致で、合うものが無くても 404 ではなく `200` の空の配列を返す。`heads/release/` のように末尾の `/` を付けると
  `release/…` だけに絞れる（付けないと `release-x` も合う）。`refs/heads/`・`refs/tags/` を付けた名前で返る
- Contents API（`GET /repos/{owner}/{repo}/contents/{path}?ref=…`）の `content` は base64 を 60 文字ごとに改行した文字列。Swift では
  `Data(base64Encoded:options: .ignoreUnknownCharacters)` で読む。ファイルもブランチも無ければ 404 で、ディレクトリなら配列が返る
- ジョブの `env:` では `runner` コンテキスト（`${{ runner.temp }}`）を使えない（actionlint が「context "runner" is not allowed here」で落とす。ステップの `env:` では使える）。
  ジョブ全体で使うパスは、最初のステップで `echo "NAME=$RUNNER_TEMP/…" >> "$GITHUB_ENV"` で渡す
- GitHub の PR のマージコミットは、件名が `Merge pull request #N from <owner>/<branch>`、本文の 1 行目が PR のタイトル（既定のとき）。
  `git log --first-parent --merges <前のタグ>..develop` で `develop` に直接入った PR が取れ、epic の PR（マージコミットの親が 2 つ）の中の子 PR は
  `git log --first-parent --merges <親1>..<親2>` で取れる（`Merge remote-tracking branch …` の取り込みは件名で除く）。`Tools/release_prepare.py draft` がこれで最新情報の下書きを作る
- `workflow_dispatch` の run の一覧（`GET …/actions/workflows/<file>/runs`）は inputs を返さない。どの入力で起動した run かを見分けたいときは、ワークフローに
  `run-name: <名前> ${{ inputs.version }}` を書くと `display_title` に入る（`run-name` は表示だけでシェルには渡らない。`run:` には今までどおり env で渡す）
- `if: always()` のステップの `job.status` は、それまでに**失敗したステップ**があるかだけを表す。`|| true` で続けて `$GITHUB_OUTPUT` に結果を出したステップ（後で run を失敗にする）は含まれないので、
  Summary の出し分けには `steps.<id>.outcome` と `steps.<id>.outputs.*` を合わせて見る
- `concurrency` の同じ group で `cancel-in-progress: false` にしても、待てるのは 1 つだけ。実行中の run があるときに 2 つ続けて起動すると、先に待っていた run は取り消され（`cancelled`）、最後に起動したものだけが動く。
  「最後に送った内容が勝つ」でよい処理（Release/Notes の確定など）はこのままでよいが、アプリなどで run を追うときは、取り消された run も出ることを前提にする
- ワークフローのファイルと同じコミットの `Tools/` を使いながら別のブランチを書き換えたいときは、`actions/checkout` を `path:` を変えて 2 回使う（起動した ref を `tools`、書き換えるブランチを `ref:` で `release`）。
  `python3 tools/Tools/x.py --root release …` のように、スクリプトとリポジトリのルートを分けて渡す（release-notes.yml）
- `develop` のブランチ保護は必須チェック「No AI Attribution」（`app_id` 15368 = GitHub Actions）だけで、PR は必須ではない（`gh api repos/<owner>/<repo>/branches/develop/protection` で読める）。
  必須チェックは直接の push にも効き、push するコミット（新しい先頭）にそのチェックが要る。`GITHUB_TOKEN`（`checks: write`）で `POST /repos/{owner}/{repo}/check-runs` した check run は
  GitHub Actions のものになるので満たせる作り（release-finish.yml。実際に push が通るかはまだ確かめていない）。check run はリモートにあるコミットにしか付けられないので、先に一時ブランチへ push してから付ける
- `GITHUB_TOKEN` は workflows の権限を持てない（`permissions:` に書けない）。`.github/workflows/` のファイルが変わるコミットを push すると
  `refusing to allow a GitHub App to create or update workflow … without workflows permission` で断られ、ほかのブランチの取り込み（マージコミット）でも同じ。
  リモートにあるコミットからブランチを作るだけなら当たらない（と見込んでいるが未確認。#645 で確かめる）。避けるには workflows の権限を持つ PAT / GitHub App のトークンが要る
- リポジトリの `GET /repos/{owner}/{repo}/actions/permissions/workflow` の `can_approve_pull_request_reviews` が `false`（Settings → Actions → General の「Allow GitHub Actions to create and approve pull requests」が無効）だと、
  `GITHUB_TOKEN` では PR を作れない（`gh pr create` が失敗する）。Issue（`issues: write`）は作れる
- 再利用ワークフロー（`workflow_call`）の中の `actions/checkout` は、呼び出し元の run のコミット（`workflow_dispatch` なら起動した ref の先頭）を取り出す。別のコミットを検証したいときは、
  `_build.yml` の `ref` のように入力で SHA を渡して `with: ref:` に渡す（空文字なら既定のまま）
- public リポジトリの `schedule` のワークフローは、リポジトリに 60 日動き（push など）が無いと GitHub が無効にする（Actions の画面で Enable workflow を押すと戻る）。
  定期実行で何かを待つ処理（Release/Sync の配信の検知）は、止まったときに手で起動できるよう `workflow_dispatch` も付け、docs に有効にし直す手順を書く
- `gh api --paginate <path> --jq '<式>'` は、ページごとに jq を当てて結果を 1 行に 1 つずつ出す（`--jq` なしだとページの JSON がつながって出て、そのままでは 1 つの JSON として読めない）。
  Python では行ごとに `json.loads` する（`Tools/release_sync.py`）。`GET /repos/{owner}/{repo}/issues` は PR も返すので、`select(.pull_request == null)` で除く
- workflow_dispatch で起動した run を「実行中・済み」で見分けるときは、run-name（`display_title`）をバージョンで完全に一致させ、`status != "completed"` を実行中とみなす（`queued`・`waiting`・`requested`・`pending` もある）。
  public リポジトリでは誰でも Issue を作れるので、ワークフローが作った Issue を目印に使うときは author（`github-actions[bot]`）も確かめる
- `gh repo create --template` で作ったリポジトリは、テンプレートで Discussions を有効にしていても Discussions が無効のまま（カテゴリも 0 件）。
  そのまま依頼から Discussion を作らせると、claude は `Discussions are disabled for this repo` を見て作らずに終わる（終了コード 0）。
  REST の `PATCH /repos/{owner}/{repo}` に `has_discussions: true`（`gh repo edit --enable-discussions` と同じ）を送ると、GitHub が既定のカテゴリ（Ideas など）を作る。管理者の権限が要る（2026-10-21、Issue #719）
- GitHub の障害のとき（2026-10-22 の「Errors loading Issues, Pull Requests, and search results」）は、`GET /repos/{owner}/{repo}/issues?labels=…` が Issue があっても
  エラーにならず 200 の空の配列を返すことがあった（8 回中 3〜4 回。`gh issue list --label` の GraphQL も 8 回中 1 回）。番号での取得（`GET …/issues/{番号}`）は安定していた。
  「一覧が空なら作る」処理はこれで重複を作る（オーケストレーターが担当の全リポジトリで状態用の Issue を作り直した）ので、前に使った番号を覚えておき、作る前に番号で読んで確かめる（Issue #739）
- 移管・改名されたリポジトリを旧名の REST（`repos/{旧owner}/{repo}/…`）で操作すると、GitHub のリダイレクトを URLSession が送り直すときに `Authorization` が付かず、
  書き込みは `401 Requires authentication`、読み取りは未認証扱い（IP ごとに 60 回/時）で `rateLimited` になった。検索は新しい名前で返すので、名前で照合する処理は黙って外れる。
  GraphQL の `repository(owner:, name:)` は旧名でも移管・改名の後のリポジトリ（`nameWithOwner` が新しい名前）を返すので、今の名前はこれで確かめる（2026-10-27、Issue #757）

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
- `let table = try #require(table(x))` のように、`#require` の中で呼ぶ関数と受け取る変数が同じ名前だと、CI の Xcode 26.3 では
  マクロの展開で変数のほうが参照され「cannot call value of non-function type」でテストのビルドが落ちる（新しい Xcode のローカルでは通る）。
  テストのヘルパー関数は受け取る変数と別の名前にする
- iOS の UI テストで `app.keyboards.firstMatch.frame` はキーの部分だけで、`ToolbarItemGroup(placement: .keyboard)` の「完了」の帯はその上に重なる。
  入力欄の中心がこの帯にかかると、`tap()` が帯に当たり「Neither element nor any descendant has keyboard focus」で落ちる。
  `swipeUp()` しても `Form` の中身が画面に収まっていればスクロールしないので、下の入力欄に移る前に `keyboard-done` でキーボードを閉じる
- iOS の `Form` は画面の外の行を作らないので、UI テストで下のほうのボタン（例: 「作成を依頼する」）は `exists` が `false` になる。
  入力欄が切り替わったことは、画面の上にある要素（`template-picker` など）で確かめる。セグメントの `Picker` は `app.segmentedControls["<ID>"].buttons["<文言>"]` で引け、`isSelected` で選択中かが分かる
- iOS の UI テストでは、`Form` の中の `LabeledContent("元の PR", value: "#17")` は名前だけの StaticText（`元の PR`）と、名前と値をつないだ StaticText（`元の PR, #17`）になり、
  値だけ（`#17`）では引けない。値を確かめるときは `app.staticTexts["元の PR, #17"]` で引く
- `AskHubKit` の public な型の名前を変えた直後の `swift test --package-path AskHubKit` は、別のターゲット（`OrchestratorKitTests` など）の古いオブジェクトが残り、
  「Undefined symbols」（古い型名の `init`）でリンクが落ちることがある。コードの誤りではないので、`AskHubKit/.build` を消してビルドし直す
- ralph-loop の xcodebuild のラッパー（別の Mac で実行する）で UI テストを流すと、`.xcresult` は実行した Mac に残り、ログの末尾にそのパスが出る。
  `-resultBundlePath` で手元に書かせることはできないので、スクリーンショットはそのパスを `rsync` で取り寄せてから `xcrun xcresulttool export attachments` で取り出す
- ssh 越しに流した `xcodebuild` では、macOS 向けの署名が `errSecInternalComponent` で失敗する（ssh のセッションからはログインのキーチェーンの鍵を使えない）。
  `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=`（アドホック署名）にすれば通る。xcb は署名の指定が無ければ自動で足す。
  一度失敗した DerivedData のまま流し直すと、作りかけの署名（`.cstemp`）が残って `invalid or unsupported format for signature` になるので、別の DerivedData でやり直す
- macOS 27.2 beta の Mac では、Xcode 26.6 の iOS Simulator のテストランナーが起動しない（7〜9 分待って失敗する）。macOS のテストとビルドは通る。
  Xcode 27.1 なら起動する見込みだが、Swift の並行性チェックが厳しくなり、Xcode 26 で通るコードが `#ConformanceIsolation` のエラーでビルドできないことがある（Zankyo で発生）。
  xcb のビルド先の設定では、macOS 27 の Mac を `nosimtest` にする
- `continueAfterFailure = false` の UI テストで `override func setUp() async throws` を使うと、テストが失敗した直後にテストランナーが
  再起動し（ログに `Restarting after unexpected exit, crash, or test timeout` が出る）、`-retry-tests-on-failure` の再試行が走らないまま
  `TEST FAILED` になる（Xcode 26.3 / 26.6 で確認）。MainActor の処理（`XCUIDevice.shared.orientation` など）は、同期の `setUpWithError()` の中で
  `MainActor.assumeIsolated { … }` で呼ぶ。CI の UI テストが 1 回の揺らぎで落ちたら、まずログで失敗したテストが `Iteration 2 of 2` で再試行されているかを見る
- worktree ごとに分けた新しい DerivedData（`-derivedDataPath`）で `xcodebuild` すると、SwiftLint の Build Tool Plugin の検証
  （`Validate plug-in "SwiftLintBuildToolPlugin"`）で止まる。手元では `-skipPackagePluginValidation` を付ける（CI は `IDESkipPackagePluginFingerprintValidatation` の `defaults write`）。
  `swiftlint` が `PATH` に無い Mac では、その DerivedData の `SourcePackages/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint` で `lint --strict` を流せる（CI と同じバイナリ）
- アプリのテストターゲット（`AskHubTests`）も MainActor 既定なので、`@MainActor final class X: XCTestCase` や注釈なしの `XCTestCase` のサブクラスは
  「main actor-isolated initializer 'init(invocation:)' has different actor isolation from nonisolated overridden declaration」でビルドが落ちる。
  `nonisolated final class X: XCTestCase` にして、View を扱うテストメソッドにだけ `@MainActor` を付ける（`NSHostingView` で撮るスクリーンショットのテストなど）
- プライバシーマニフェスト（`AskHub/PrivacyInfo.xcprivacy`）は `PBXFileSystemSynchronizedRootGroup` のフォルダに置くだけでリソースに入る
  （iOS は `AskHub.app/PrivacyInfo.xcprivacy`、macOS は `Contents/Resources/PrivacyInfo.xcprivacy`）。
  理由の申告が漏れていても Upload（TestFlight）は成功するので、CI では気づけない。`UserDefaults` 以外の理由の申告が要る API を使い始めたら、ここに理由を足す（`docs/app-review.md`）
- ツールバーの `Menu` の中の `Picker`（`.pickerStyle(.inline)`）の項目は、iOS の UI テストでは `app.buttons["<項目の文言>"]` で引けて、`tap()` で選べる。メニュー自体は `app.buttons["<Menu のラベル>"].firstMatch` で開く。
  一覧の並びは行の `staticTexts[…].frame.minY` を比べて確かめる
- 開発者モード（`DevToolsSecurity -status` が disabled）の Mac では、launchd から動く `xcodebuild test` の Simulator のテストが
  「unable to connect to "com.apple.instruments.deviceservice.lockdown" … DTServiceHubClient failed to bless service hub」の後に始まらず、`** BUILD INTERRUPTED **` で終わる。
  Simulator の再起動・作り直し・`testmanagerd` の停止では直らない。テストのホストに接続する権限を得るたびに認証を求められ、launchd のジョブには認証の画面が無いため。
  `sudo DevToolsSecurity -enable` で直る（`_developer` グループへの所属も要る）
- macOS を `CODE_SIGNING_ALLOWED=NO` でアーカイブすると、`ENABLE_APP_SANDBOX` などから作られるエンタイトルメントが実行ファイルに埋め込まれない（`codesign -d --entitlements -` で何も出ない）。
  `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER=`（アドホック署名）でアーカイブすれば、証明書が無くても `com.apple.security.app-sandbox` などが埋め込まれる。
  Mac App Store は App Sandbox を必須にしているので、`_archive.yml` の macOS はアドホック署名でアーカイブし、配布用の署名は Export に任せている
- Mac App Store へのアップロードには Info.plist の `LSApplicationCategoryType` が要る（iOS では要らないので、iOS だけ上げていた間は無くても気づかない）
- `Tools/` の Python の unittest は `python3 -m unittest discover -s Tools/tests -t .` で流す（`Tools/` に `__init__.py` は無いが、名前空間パッケージとして 3.9 でも見つかる）。
  テストは `from .fake_app_store_connect import …` と相対で import し、`Tools/` のモジュールは偽物のモジュールが `sys.path` に足したうえで読む。
  PyJWT は `app_store_connect.make_token` の中でだけ import するので、`make_token` を `mock.patch` し、`AppStoreConnect(urlopen=…, sleep=…)` で HTTP と待ち時間を差し替えれば、PyJWT の無い Mac でもネットワークに出ずに流せる。
  `Tools/*.py` のモジュールの先頭で PyJWT などの外の依存を import しない（`--check` や unittest まで依存を求めてしまう）
- App Store Connect のバージョン（`appStoreVersions`）は iOS と macOS で別にあり（`filter[platform]=IOS` / `MAC_OS`）、言語ごとの掲載文（`appStoreVersionLocalizations`）とスクリーンショットのセットもバージョンごとに持つ。
  iOS だけに反映すると macOS の掲載文は空のまま。`Tools/upload_metadata.py`・`upload_screenshots.py` は `--platform` ごとに 1 回ずつ実行する。Mac のスクリーンショット（`APP_DESKTOP`）は 16:10 の 2880x1800・2560x1600・1440x900・1280x800 だけを受け付ける
- `NSHostingView` を載せた `NSWindow` を `cacheDisplay(in:to:)` で PNG にするとき、`hostingView.superview`（ウィンドウの枠の View）を描くと、タイトルバーに出るタブ（`TabView`）とツールバーのボタンまで写る。
  `NSBitmapImageRep(pixelsWide: 2880, pixelsHigh: 1800, …)` の `size` を 1440x900 ポイントにすると、画面の倍率によらず 2 倍で描ける
- 上の方法で撮るウィンドウはマウスの操作を受けるので、手元の Mac ではポインタの下の `List` の行が選ばれ、`NavigationLink` の詳細が開いた状態で写った。`window.ignoresMouseEvents = true` にする。
  また、一度描いた後にサンプルデータが入ると `List` の行の高さが計算し直されず、行が重なって写る（要対応のタブ）。待った後にウィンドウの大きさを 1pt 変えて戻すと計算し直される
- `xcodebuild test` に `TEST_RUNNER_<名前>=値` の環境変数を付けると、テストのプロセスには `<名前>` で渡る（スキームを変えずにテストへ値を渡せる）。
  Swift Testing の `@Suite(.enabled(if: …))` の条件は MainActor の外で評価されるので、MainActor 既定のターゲットでは条件に使う型を `nonisolated` にする（しないと「main actor-isolated static property can not be referenced from a Sendable closure」）
- iOS 26 の `confirmationDialog`（`titleVisibility: .visible`）は、押したボタンから出る吹き出し（popover）で出る。UI テストではタイトルを `app.staticTexts["<タイトル>"]` で引ける。
  ダイアログのボタンが元のボタンと同じ文言だと `app.buttons["<文言>"]` が 2 つに当たるので、元のボタンに `accessibilityIdentifier` を付け、
  ダイアログのボタンは `NSPredicate(format: "label == %@ AND identifier != %@", …)` で引く
- `Tools/tests/` で一時ディレクトリの git リポジトリを使うテストは、git を何十回も起動するので遅い（ローカルで 1 テスト数秒になることがある）。
  読むだけのテストは履歴を `setUpClass` で 1 度だけ作り、履歴を変えるテストだけを別のクラスにする。テストの git は `GIT_CONFIG_GLOBAL=/dev/null` で手元の設定（署名・フック）を読ませない
- Python の `http.client.IncompleteRead`（応答の途中での切断）は `http.client.HTTPException` の子で、`OSError`・`urllib.error.URLError` の子ではない。
  `urlopen` の失敗を `except (URLError, OSError)` だけで受けると、`response.read()` の途中の切断が traceback になる（`Tools/app_store_connect.py` は `HTTPException` も受ける）
- iOS の UI テストで `Form` の中の `NavigationLink` を開いて戻ると、開く前にスクロールした位置のままになる。`swipeUp()` でどこまで流れるかは Mac の負荷で変わり、
  CI では上の行が画面の外（作られない）に出て、戻った後に上の行の文言を待つと手元では通るのに落ちた（#652）。戻った後に探す行は `swipeDown()` で戻してから探す。
  手元で CI の状態を作るには、開く前のスワイプを一時的に `swipeUp(velocity: .fast)` にする
- visionOS の Simulator は、destination では `platform=visionOS Simulator`、SDK は `xrsimulator`、`xcrun simctl list runtimes` では `visionOS 26.5 (…) - com.apple.CoreSimulator.SimRuntime.xrOS-26-5` の形（識別子だけ `xrOS`）。
  ランタイムを選ぶ・Simulator を作るスクリプトでは、表示名と識別子の名前を別に持つ（`scripts/orchestrator/xcb`）
- サンプルの添付（`AttachmentFile.samples`）は依頼・回答・「問題あり」の UI テストで共通に使う。行を足すと添付欄の注意書き（footer）と削除のボタンが画面の外に押し出され、
  Form が作らないので `exists` が false になる。確かめる前に `scrollToHittable`（`AskHubUITests+Scroll.swift`）で出るまでスクロールする。送信の件数（「添付 N 件」）の期待値も 3 つのテストで直す
- 「新しい依頼」の「依頼を送る」は添付欄の注意書き（footer）のすぐ下にあり、iPhone 17 Pro では開いた直後に画面の外になる（#780）。注意書きの文言を変えたら、依頼タブの UI テストも流す。
  依頼タブを開いたことは上の `repository-picker` で待ち、「依頼を送る」は `scrollToHittable` で出してから確かめる・押す。epic 宛ての子 PR では CI の UI テストが走らないので、最終 PR で初めて落ちる

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
- `AttributedString(markdown:)` の `.full` は GFM の表を解釈し、セルの run の `presentationIntent` に `tableCell(columnIndex:)`・
  `tableHeaderRow`（ヘッダー）か `tableRow(rowIndex:)`（本文。1 から）・`table(columns:)`（列の揃え）が内側から外側の順に並ぶ。
  空のセルや空の行には run が無いので、列・行の番号で位置を決めて空のセルを埋める。区切り行より多いセルは落ちる。
  空行を挟まずに表の直後に書いた行は、GitHub と同じく表の行になる
- GFM の表のセルの中では、列の区切りにしないため `|` を `\|` と書く。`AttributedString(markdown:)` はコードスパンの外の `\|` は `|` に戻すが、
  コードスパンの中（`` `a \| b` ``）では `\` を残す（GitHub は `|` に戻す）。表のセルのコードの run だけ `\|` を `|` に戻す
- 配列リテラルの要素に `x.map { … } ?? "-"` や `+` での文字列の連結を何個も並べると、「the compiler is unable to type-check this expression in reasonable time」でビルドが止まる。
  表の 1 行のような組み立ては、要素ごとに `var` で作ってから配列にする（`BuildHost.tableCells`）
- `FileHandle.readToEnd()` は、読む位置がファイルの終わりにあると空の `Data` ではなく `nil` を返す。`try?` で受けると読めなかったのと区別できないので、
  `try handle.readToEnd() ?? Data()` で受け、`catch` だけを失敗として扱う
- Swift Testing の `#expect(...)` の中では mutating なメソッドを呼べない（「cannot use mutating member on immutable value」）。結果を `let` で受けてから `#expect` に渡す
- 引数の型だけが違う同名のメソッド（`record(_ outcome: ReviewOutcome, …)` と `record(_ outcome: FixOutcome, …)`）に、両方の enum にある `.failed(reason:)` を渡すと
  「ambiguous use of」になる。`FinalReviewTracker.ReviewOutcome.failed(reason:)` のように型を書く
- Swift の `String` は `"\r\n"` を 1 つの `Character` として扱うので、`split(separator: "\n")` では CRLF の行を区切れない。
  `split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)` で区切る
- MainActor 既定のターゲットでは、型の中に入れ子にした型（`private struct X`）も MainActor になる。`nonisolated static func` の中でその型を作ると
  「main actor-isolated initializer … cannot be called from outside of the actor」になるので、入れ子の型にも `nonisolated` を付ける。
  `nonisolated` の関数から MainActor の文言の関数（`InboxModel.message(for:)` など）を呼びたいときは、エラーのまま返して MainActor の側で文言にする（`ReleaseProgress.load`）
- MainActor 既定のアプリのターゲットに App Intents の型（`AppEntity`・`EntityQuery`）を置くときは、`nonisolated struct` にする（フレームワークは任意のスレッドから呼ぶので、Sendable な nonisolated の準拠が要る）。
  `nonisolated` の `async` のメソッドからは、MainActor の型（Keychain・UserDefaults・`IdeaRequestModel.message(for:)` を使うもの）を `await` で呼べばよく、警告は出ない。
  ビルドすると `AskHub.app/Metadata.appintents/extract.actionsdata`（JSON）の `entities` に型が出る。macOS の `xcodebuild test` のログに出る `com.apple.linkd.autoShortcut` への接続の失敗は、テストの結果に関係しない
- `@Parameter` を持つ `AppIntent` は `nonisolated struct` にできない（「'nonisolated' cannot be applied to mutable stored properties」）。MainActor 既定のまま `struct` にすると、Swift 6 でも警告なしでビルドでき、
  `perform()` は MainActor で動く（async の要件なので MainActor の実装で満たせる）。`@Parameter` の `inputOptions` は `requestValueDialog` より前に書く（逆だと「argument 'inputOptions' must precede argument 'requestValueDialog'」）。
  `extract.actionsdata` の `actions.<型名>` で `openAppWhenRun`・`authenticationPolicy`（`.requiresAuthentication` にすると `1`）・`parameters` を確かめられる
- App Shortcuts のフレーズのローカライズは `AppShortcuts.xcstrings`（名前は固定）に書き、キーはコードのフレーズの `\(.applicationName)` を `${applicationName}` にしたもの。
  `knownRegions` に `ja` が無くても `ja` の訳があればビルドしたアプリに `ja.lproj/AppShortcuts.strings` が入る（`en` の値も書くと `en.lproj` もできる）。登録の結果は `extract.actionsdata` の `autoShortcuts` で確かめられる。
  `ja.lproj` ができると、日本語の端末ではアプリの言語が `en` ではなく `ja` に解決される（`Bundle.preferredLocalizations(from: ["en", "ja"], forPreferences: ["ja-JP"])` が `["ja"]`）ので、システムが出す文言（標準のボタンなど）が日本語になる。実機での見え方は実機確認で確かめる
- App Intents の `SiriTipView` は macOS で使えず（`@available(macOS, unavailable)`）、`ShortcutsLink` も iOS の SDK にしか無い。iOS と macOS で同じ View を使うなら、どちらも使わずに文章で案内する（使うなら `#if os(iOS)` が要る）
- Compression の `COMPRESSION_ZLIB`（Foundation の `NSData.compressed(using: .zlib)` も）はヘッダの無い raw Deflate（RFC 1951）で、zip の項目の中身（圧縮方式 8）をそのまま解ける。
  CRC-32 は `import zlib` の `crc32` で計算できる（外部の Package は要らない）。zip 爆弾に備え、`compression_stream` で少しずつ解いて書いた量を数える（`AttachmentZipWriter`）
- `Data(contentsOf:options: .mappedIfSafe)` で mmap して読んでいるファイルを、別の処理が同じパスで切り詰めて書き直すと、読む側が SIGBUS で落ちうる。
  読まれうるファイルは `data.write(to:options: .atomic)`（別のファイルに書いてから rename）で書く（`Orchestrator.prepareZip`）。
  actor の中で重い同期の I/O をするときは、`Task.detached { Result { () throws(E) -> T in … } }.value` で actor の外に出すと、型付きの throws のまま Sendable の警告なしで受け取れる

## シェルスクリプト

- bash で `"$CONFIG（…）"` のように変数の直後に全角文字を書くと、バイト単位で変数名の一部と読まれ、`set -u` で unbound variable になる。
  日本語が続く変数は `${CONFIG}` と波かっこで囲む
- launchd の LaunchAgent は既定でジョブの終了時にプロセスグループごと止める。子プロセス（ループなど）を残したいときは `AbandonProcessGroup` を `true` にする
- zsh では `$C:refs/...` のように変数の直後に `:r` などが続くと修飾子（拡張子の除去など）として解釈される。`git push origin "${C}:refs/heads/…"` のように波かっこで囲む
- `git status --porcelain` は、中身がすべて未追跡のディレクトリを `?? .claude/` のように 1 行にまとめる。ファイル名で除外したいときは `--untracked-files=all` を付ける
- `git remote get-url origin` は `url.<base>.insteadOf` で書き換えた後の URL を返す。設定に書かれた URL と比べるときは `git config --get remote.origin.url` を使う
- squash merge 済みのブランチは、コミットがどのリモートにも無いので「未 push」に見える。`git merge-tree --write-tree <既定ブランチ> <ブランチ>` の木が既定ブランチの木（`<既定ブランチ>^{tree}`）と同じなら、取り込んでも何も変わらない（変更はすべて既定ブランチにある）と判定できる（git 2.38 以降）
- 変数の直後の全角文字は、見つけた 1 か所だけ直すと同じ書き方がほかのスクリプトに残る（#133 で start-loop.sh だけを直し、askhub-manual.sh などに残っていた）。
  直すときは `LC_ALL=C grep -rnE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' scripts` で、変数の直後に ASCII 以外が続く箇所をすべて洗い出す
- `--model` を付けない `claude -p` は、アカウントの既定のモデルで動き、その既定は知らせなく変わる（2026-10-15 にループが Opus 5.5 から Fable 5.1 に切り替わっていた）。
  オーケストレーターは設定の `model`（既定 Opus 5.5）を `ANTHROPIC_MODEL` で、`effort` を `CLAUDE_CODE_EFFORT_LEVEL` で渡す（どちらも claude が読む環境変数。引数の `--model` / `--effort` が優先）。
  ループのログはテキスト出力でモデル名が残らないので、実際のモデルは `~/.claude/projects/<作業ディレクトリ>/*.jsonl` の `message.model` で確かめる
- bash の `IFS=$'\t' read -r a b` は、タブが IFS の空白文字なので先頭の空の値を詰める（`\txhigh` が a=xhigh になる）。
  空になりうる値を受け渡すときは、`key=value` の行にして `sed -n 's/^key=//p'` で読む
- `claude` の `--tools` / `--allowedTools` / `--disallowedTools` / `--add-dir` は値を複数とる（`<tools...>`）。直後に位置引数のプロンプトを置くと、ツール名として飲み込まれて
  プロンプトが空になり、`-p` が失敗する（偽の claude では気づけない）。プロンプトは標準入力で渡すか、`--` で区切る。
  差分などの信用しきれない文を読ませるときは、`--restricted --strict-mcp-config --tools "Read,Grep,Glob" --add-dir <読ませる場所>` で、読むツールだけ・作業ディレクトリの中だけに限れる
- コマンド置換（`$(f)`）の中で呼んだ関数の `exit` は、サブシェルしか終わらせない。失敗の行も置換の値に吸い込まれる。
  `set -e` のスクリプトでも、単独の代入（`v=$(f)`）なら止まるが、条件（`[[ "$(f)" == … ]]`・`if`）・ほかのコマンドの引数（`echo "$(f)"`）・`local v=$(f)` の中では止まらずに進む。
  失敗で終わらせたい関数（`failed` など）は置換の外で呼び、値はグローバル変数で受け渡す
- `set -o pipefail` のもとで `cmd | grep -q` を使うと、出力が長いとき `grep -q` が先に終わって `cmd` が SIGPIPE（141）で終わり、一致したのにパイプ全体が失敗になる。
  出力を変数に入れてから調べるか、`grep ... >/dev/null` にする
- `Process` で起動したスクリプトに `kill(pid, SIGTERM)` を送っても、スクリプトが起動した `claude` などの子孫は止まらない（オーケストレーターと同じプロセスグループにいるので、グループごとにも送れない）。
  bash は前景の子（コマンド置換の中のパイプなど）を待つ間は SIGTERM の処理を待たせるので、子が動き続ける限りスクリプトも終わらず、SIGKILL で終わると `trap … EXIT` の後片付けも走らない。
  制限時間で止めるときは、送る前に `proc_listchildpids` で子孫を集め（親が先に終わると launchd に付け替えられて辿れない）、まとめて送る。スクリプトには `trap 'exit 143' TERM` を置いて後片付けを走らせる
- `trap 'status=$?; …; exit "$status"' EXIT` のように trap の文字列の中で代入すると、shellcheck は代入を見つけられず SC2154（referenced but not assigned）の警告を出す（`-S warning` で落ちる）。
  処理を関数（`on_exit() { status=$?; …; }`）にして `trap on_exit EXIT` にする。関数の先頭の `$?` は trap が起きたときの終了コードのまま
- macOS の `/bin/bash`（3.2）には連想配列（`declare -A`）が無い（`declare: -A: invalid option`）。bash 3.2 で動かすスクリプト（`capture_screenshots.sh` など・ワークフローの `run:` を手元で流す道具）では、
  `eval "name_$key=…"` か、`key=value` の行のファイルで代わりにする
- テンプレートの `scripts/rename.sh` を手元で確かめるときは、最後に `gh repo view` / `gh repo edit --enable-discussions` を本物のリポジトリに向けて呼ぶので、`printf '#!/bin/sh\nexit 1\n'` の偽の `gh` を前に置いた PATH で流す。警告が出るだけで名前の変更は終わる（2026-10-21、visionOS のテンプレート）
- ralph-kit の `install.sh <checkout>` は中継のファイルを置き、CLAUDE.md の ralph-kit:snippet の目印の間を書き換えるだけで、CLAUDE.md に「## ralph-loop による自律開発」の節が無いときは
  案内を表示して終了コード 0 で終わる（節は足さない。コミットもしない）。節の無いリポジトリに入れるときは、先に kit の `templates/CLAUDE.snippet.md` の見出しから end の目印までを足してから流す（`add-repo.sh`）
- 同じ内容のコミットを作り直してブランチに push し直すと、コミットの時刻が違うので fast-forward にならず断られる。やり直しで同じブランチに push するスクリプトは、
  `git fetch origin refs/heads/<branch>` の後に `FETCH_HEAD^{tree}` と `HEAD^{tree}` を比べ、同じなら push を飛ばす（force しない）
- 偽の `gh` とローカルの bare リポジトリでスクリプトを確かめるときは、clone した checkout の origin を `https://github.com/<owner>/<repo>.git` にしたうえで
  `url.<bare のパス>.insteadOf` で書き換え、`GIT_ALLOW_PROTOCOL=file` を付けて流す。書き換えが漏れても https に出られないので、本物の GitHub に push しない
- macOS の `zipinfo` は、ロケールが C（launchd から起動したときの既定）だと UTF-8 の名前を `??` と出す（`LC_ALL=en_US.UTF-8` なら出る）。`unzip` は名前の引数をワイルドカードとして扱い
  （`a[1].txt` を渡すと「filename not matched」）、名前の位置の `-d` などもオプションとして読む。`[` `]` `*` `?` と先頭の `-` の前に `\` を付けると一致する。macOS の `zip` は UTF-8 の名前でも汎用フラグの bit 11 を立てない

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
- `Menu` の中で `Section("見出し") { Picker(…).pickerStyle(.inline) }` と包んでも、iOS 26 のメニューには見出しが出ず、区切り線だけになる（`Picker` の中に置く `Section` とは違う）
- UI テストの Simulator は端末の言語が英語のままなので、`Locale.current.localizedString(forIdentifier: "ja")` は「Japanese」になる。
  アプリの画面は日本語だけなので、言語名は `Locale(identifier: "ja").localizedString(forIdentifier:)` で日本語にする（「日本語」）
- SwiftUI の `List`（iOS では `UICollectionView`）は、差分を当てるときに整合性を検証し、矛盾すると `-[UICollectionView _validateSortedDeleteItems:moveItems:…insertItems:…]` の `NSAssertionHandler` で落ちる（バックトレースにアプリのフレームが無い）。
  主な原因は (1) 同じ `ForEach` の要素の id の重なり（GitHub の search を `first`+`after` でページングすると、取得中に順位が動いて同じ要素が 2 ページに出る・organization の設定の重複・大文字小文字だけ違うリポジトリ名）と、
  (2) `ForEach` の 1 要素から出る行の数が更新の前後で変わること。一覧に出す取得結果は AskHubKit の `uniqued(by:)` で id ごとに先のものを残し、リポジトリ名・login の id は小文字にする（2026-10-23、Discussion #743）
- ステータスタブの行の `swipeActions` の `Button(role: .destructive)`（「担当から外す」）は、押すと SwiftUI が行を消す前提で差分を当てるため、シートを出すだけで行が残ると
  `-[UICollectionView _Bug_Detected_In_Client_Of_UICollectionView_Invalid_Number_Of_Items_In_Section:]` で落ちる（デモモードでも毎回。iOS 26.5・27.0）。コンテキストメニューの同じボタンでは落ちない。
  行を消さないスワイプのボタンには role を付けず `.tint(.red)` にする（コンテキストメニューは `.destructive` のままでよい）。UI テストはスワイプの経路でも流す（2026-10-26、Discussion #743）
- 一覧の差分で落ちないかを UI テストで確かめるときは、DEBUG だけの起動引数（`-AskHubSampleChanges`）でサンプルの取得元が更新のたびに違う中身（増減・並びの入れ替え・重複）を返すようにし、
  `collectionViews.firstMatch` の上のほうから下へ `press(forDuration:thenDragTo:)` で引っぱって更新を繰り返す。落ちると `app.state` が `.runningForeground` でなくなる
