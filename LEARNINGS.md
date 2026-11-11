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
- Contents API の書き込み（`PUT /repos/{owner}/{repo}/contents/{path}`）は、すでにあるファイルを `sha` なしで書くと 422（本文に `"sha" wasn't supplied`）、古い `sha` を付けると 409 を返す。
  返る `content.sha` は Git の blob の sha（`git hash-object` と同じ）。読み取りに `If-None-Match` で ETag を付けると、変わっていなければ 304 が返る（2026-11-03、`AskHubStateStore` の `LiveGitHubContentsStoreTests` で確かめた）
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
- Contents API のディレクトリの一覧は 1,000 件までで、続きを読む方法が無い。人の意図のように増え続けるディレクトリは、親の一覧からディレクトリの tree の sha を読み、
  Git Trees API（`git/trees/<sha>?recursive=1`。10 万件・7 MB まで。超えると `truncated` が true）で下まで 1 度に読む。tree は sha で中身が決まるので、ETag で使い回せる（2026-11-06）
- Contents API で 1 MB を超え 100 MB 以下のファイルを既定のメディアタイプ（`application/vnd.github+json`）で読むと、エラーにならず `encoding: "none"`・`content: ""` で返る（`object` のメディアタイプと同じ。2026-11 に 1.4 MB のファイルで実測）。
  中身は `application/vnd.github.raw+json` で読み直す。100 MB を超えるファイルは Contents API では読めない（GitHub の文書）。`object` に切り替えると、ディレクトリが配列ではなく `entries` を持つ object で返るので、一覧の処理が壊れる（2026-11-06）
- git の設定は、`GIT_CONFIG_COUNT`・`GIT_CONFIG_KEY_<n>`・`GIT_CONFIG_VALUE_<n>` の環境変数でファイルに書かずに渡せる（`core.hooksPath=/dev/null`・`credential.helper` など）。`GIT_CONFIG_GLOBAL=/dev/null`・`GIT_CONFIG_NOSYSTEM=1` で人の設定を読まない。
  `clone --filter=blob:none --no-checkout` の後に `worktree add --detach <path> origin/HEAD` で取り出すと、要るファイルだけを取りにいく。資格情報の無い private リポジトリは、`GIT_TERMINAL_PROMPT=0` のとき `could not read Username for 'https://github.com': terminal prompts disabled` で失敗する（Apple Git 2.54 で確かめた。2026-11-06）
- organization の Actions の使用量は、`gh api "organizations/<org>/settings/billing/usage?year=<年>&month=<月>"` でリポジトリごと・SKU（`Actions Linux` など）ごとに読める（`unitType` が `Minutes`）。
  前の `orgs/<org>/settings/billing/actions` は `410`（moved）を返す。public のリポジトリの分も載る（`discountAmount` で無料になる）ので、private の枠（Free の organization は月 2,000 分）を見積もるときは private のリポジトリだけを足す。
  private のリポジトリでは 1 回のジョブが 1 分に切り上げて数えられるので、数秒で終わる定期実行でも 1 時間ごとで月 720 分になる（2026-11-07、司令塔の見張りの間隔を決めたとき）
- fine-grained token で PR を扱うときの権限（GitHub の「Permissions required for fine-grained personal access tokens」の表）: マージ（`PUT …/pulls/{n}/merge`）とブランチの削除（`DELETE …/git/refs/…`）は
  Pull requests ではなく **Contents の write**、落ちた job の流し直し（`POST …/actions/runs/{id}/rerun-failed-jobs`）は **Actions の write**、combined status（`GET …/commits/{ref}/status`）は Commit statuses の read。
  check runs の一覧（`GET …/commits/{ref}/check-runs`）は表に載っていない。足りないかは応答の `X-Accepted-GitHub-Permissions` ヘッダーで分かる（2026-11-07、`AskHubPullRequests`）
- REST の check run の `name` は、再利用ワークフロー（`workflow_call`）のジョブだと `build / build` のように「呼び出し側のジョブ / 呼ばれた側のジョブ」になる（この repo の CI で確かめた）。
  待つチェックの名前の一覧には、PR の画面のチェックの名前をそのまま書く（2026-11-07、`AskHubPullRequests`）
- GraphQL の一次の上限は、エラーの状態コードではなく `200` に `errors` を付けて返り、`x-ratelimit-remaining` が `0` になる（二次の上限は 200 か 403）。
  `data` だけを見て `null` を「無い」と扱うと、上限を見落とす。`errors` と `x-ratelimit-reset` を先に見る（GitHub の文書。2026-11-07、`AskHubPullRequests`）

- git のブランチ名は、ほかのブランチ名を「フォルダ」として含められない。`askhub/E` があると `askhub/E/t1` は
  「cannot lock ref 'refs/heads/askhub/E/t1': 'refs/heads/askhub/E' exists」で作れない（GitHub でも同じ）。作業ブランチの下に子ブランチを作るときは、`askhub/E-t1` のように `/` で区切らない（2026-11-07、`TaskBranches`）
- GitHub Actions の job のログ（`GET …/actions/jobs/{id}/logs`）は、短い間だけ使える署名つきの URL への 302 で返る。リダイレクトを追わない `URLSession` では、
  `Location` を読んで `Authorization` を付けずに取りに行く（署名で認められる。トークンを別のホストに渡さない）。各行の先頭に `2026-11-07T09:00:00.1234567Z ` の形の時刻が付く（2026-11-07、`jobLog`）
- fine-grained token の期限は、そのトークンで呼んだ API の応答の見出し `github-authentication-token-expiration` に `2027-10-23 12:25:03 UTC` の形で出る（`+0900` のような時差の形で返ることもあると報告がある）。
  期限の無いトークンには見出しが無い。期限切れのトークンは 401 で見出しも無いので、切れた後に期限を知るには前に読んだ値を覚えておく。
  期限だけを読むなら `GET /rate_limit` が REST の上限に数えられない（2026-11-08、`GitHubTokenExpiry`）
- 司令塔は状態を書き換えてから受け付けた記録（`consumed/`）を書くが、クライアントが状態リポジトリを並べて読む 1 回の読み込みでは、記録は新しく状態は古い組み合わせを読むことがある
  （状態のファイルを先に読み終え、その後に記録を読んだとき）。受け付けを見つけた読み込みだけで「反映された」とせず、その後に始めた読み込みが終わるまで反映中にする（`ReflectionTracker`。2026-11-09、反映中の UI）
- CodeRabbit は、PR の head のコミットに付ける印を、commit status `CodeRabbit` から check run `CodeRabbit`（アプリの slug は `coderabbitai`）に切り替えた（2026-10-25 までは commit status、2026-11-01 以降は check run）。
  完了は `completed`・`success`（見出し "Finished"）、上限は `completed`・`neutral`（"Review rate limited"）、見送りは `completed`・`skipped`（"Review skipped…"）。commit status だけを読むと、終わっていても「始まっていない」に見える
- GitHub は、コミットを書き手（author）のメールアドレスでアカウントに結び付ける。どのアカウントにも登録されていないアドレス（`worker@askhub.invalid` など）のコミットは、名前だけが出てアカウントに結び付かない。
  本当のアドレスを出さずに結び付けるには、noreply アドレス `<id>+<login>@users.noreply.github.com`（`GET /user` の `id`・`login`）を使う。草（contributions）に数えられるのは、既定のブランチに入ったコミットだけ
- GitHub のブランチの自動の削除（リポジトリの設定の `delete_branch_on_merge`）が有効なリポジトリでは、PR をマージした直後に head ブランチを API で消すと、
  GitHub が先に消して DELETE（`…/git/refs/heads/<branch>`）が 404 になることがある（422 の "Reference does not exist" ではなく）。直前の GET では残って見える。
  マージの後の片付けは、DELETE の 404 も 422 と同じく読み直し、無ければ消えたものとして扱う（2026-11-09、prime-pick-ios の最終 PR のマージで司令塔が止まった。`deleteBranch`）

- PR の本文の画像の添付（gh の `--attach`）は、`POST https://uploads.github.com/user-attachments/assets?name=<名前>&content_type=image/png&repository_id=<リポジトリの数の id>` に中身をそのまま送ると、
  `{"url": "https://github.com/user-attachments/assets/<id>"}` が返る（cli/cli の `internal/attachments`）。書き込みの権限が無いトークンには 403 ではなく 404 を返す。
  public のリポジトリでは誰でも見られ、消せない（2026-11-09、`GitHubPullRequests.uploadAttachment`）
- 司令塔の受け付けを早く知るために、送った意図の処理の記録（`consumed/<device>/<nonce>.json`）を Contents API で数秒ごとに読むと、記録がまだ無い間は 404 が返り、
  404 は ETag で 304 にできないので GitHub の上限（5,000 回/時）に数えられる（4 秒ごとなら 1 つの意図で 900 回/時）。待っている意図のうち一番前に送ったもの（司令塔は番号の順に処理する）だけを確かめ、
  受け取りが遅い（3 分を過ぎた）意図は 30 秒ごとの全体の取り直しに任せ、上限の 403/429 は `retryAfter` の間だけ休む。`consumed/<device>` の一覧を読む案は、Contents API の一覧が 1,000 件までで、
  ULID の名前の新しい記録が後ろに来るため、送った意図が増えると新しい記録が一覧から外れるのでやめた（2026-11-10、`ClientStore.watchReceipts`）
- Contents API の読み取りは、ETag で 304 になっても 1 回ずつ往復し、1 回およそ 0.3 秒かかる。司令塔のジョブの見回りは、1 周で約 110 件（epic・ジョブ・試行）を 1 件ずつ読み、
  すべて 304 でも約 30 秒かかっていた。Git の tree と blob は sha で中身が決まるので、直下の一覧（ETag つき）だけを毎回読み、その下は前に読んだ tree と blob を使い回すと
  （`StateStore.snapshot()`）、変わっていなければ 1 回・0.3 秒になる（起動の直後の 1 回目は、今までと同じ回数を 200 で読む）。blob は `GET …/git/blobs/{sha}` に
  `Accept: application/vnd.github.raw+json` を付けると、base64 の JSON ではなく中身がそのまま返る（中身から求めた blob の sha が一致することを確かめた。2026-11-10、#989）
- Actions のワークフローを `paths`・`paths-ignore` で絞ると、当たらない変更ではワークフローの実行そのものが作られず、check run が 1 つも出ない（skipped のチェックも出ない）。
  AskHub のワーカーは待つチェック（`repo.json` の `build.childChecks`・`finalChecks`）が出るのを 30 分待って「始まらない」の失敗にし、ルールセットで必須にしたチェックなら PR をマージできない。
  ドキュメントだけの #992 には `build` も `build / build` も無かった。待つチェックを出すワークフローは絞らない（2026-11-10、shariverse/oshikatsu-countdown-ios#161・#997）
- 再利用ワークフロー（`workflow_call`）を呼ぶジョブが `if` で飛ばされると、check run は `build / build` ではなく呼び出し側のジョブ名だけ（`build`）で、conclusion が `skipped` になる
  （この repo の PR の synchronize で確かめた）。待つチェックの名前と別なので、飛ばしたイベントの回を成功と取り違えることはない（2026-11-10、#997）
- 今の仕組みの CI に残っている `epic/**` の判定（子 PR では PR のイベントで Build を動かさない）は、新しい作業ブランチ `askhub/**` に当たらない。
  そのままだと子 PR（`askhub/<epic>-<task>` → `askhub/<epic>`）が push と PR のイベントで 2 回流れ、PR のほうは UI テストまで流す（#983 で 5 分と 25 分）。移すときに `askhub/` に読み替える（2026-11-10、#997）
- この repo の Build は、`askhub/**` の最終 PR を除き、PR の更新（synchronize）では UI テストを流さず、push の回も Unit テストだけになる。
  UI テストを含めて流し直すには、`gh run rerun` のほかに、PR を `gh pr close` → `gh pr reopen` する（reopened のイベントで UI テスト込みで動く）。
  これが効くのは base が `askhub/**` でない PR（develop 宛てなど）だけ。`askhub/**` 宛ての子 PR は、開き直しても PR のイベントで Build が動かない（`build.yml` の `if`）ので、
  子 PR のコードの UI テストは手元で流すか、最終 PR（`askhub/<epic>` → develop）で流す
  CI でだけ揺らぐテストを調べるときは、マージしない下書きの PR で `_build.yml` のテストを `-only-testing` で絞ると、ビルドを含めて 4 分ほどで 1 回を流せる（2026-11-10、#1006）
- organization・ユーザーのアバターは、トークンなしで `https://github.com/<login>.png?size=<画素>` から取れる（`avatars.githubusercontent.com/u/<id>?s=<画素>` へ 302 で転送する。`AsyncImage` は転送を追う）。
  デモのデータの架空の名前（`demo-studio` など）で取ると、同じ名前の実在のアカウントの画像が写るので、デモでは取らずに記号のアイコンで描く（2026-11-11、#1017）
- GitHub の REST の上限（1 時間に 5,000 回）は、トークンごとではなくアカウントごとに数える。同じアカウントの fine-grained token（司令塔・アプリ）と `gh` の OAuth のトークンは、同じ 5,000 回を分け合う。
  使い切ると、アプリ（「取り直せませんでした」）も司令塔も Claude のセッションの `gh` も、戻るまで止まる。`gh api rate_limit` は上限に数えられないので、使われ方は 1 分ごとの `used` の増え方で測る。GraphQL の上限は別に数える
- epic の進み具合を見張るときは、`askhub status`（1 回で REST の要求が約 30 回）を短い間隔で流さない。2026-11-11 に 2 つのセッションが 15〜30 秒おきに流し、1 時間の上限を使い切った。
  見張るなら、上限に数えられない司令塔のログ（`ssh macmini 'tail ~/Library/Logs/AskHub/commander.log'`）を見る。状態リポジトリをまとめて読むなら、git の clone・fetch（REST の上限に数えられない）を使う
- `askhub status` は、初めて読むときは読んだものがすべて上限に数えられる（11/11 の状態で `--repo` 1 つが 30〜70 回、`--repo` なしが約 280 回）。
  状態リポジトリの写し（`snapshot()`）から読むので、無いファイルの 404 は出ない。tree と blob は `~/Library/Caches/jp.shilokuma.AskHub.cli/state-objects` にも持つので、
  次の実行からは直下の一覧の 1 回（ETag はメモリーにだけ持つので 200）と変わった分だけになる。`askhub status --watch <秒>`（60 秒以上）は 1 つのプロセスで読み直すので、
  変わらない周は直下の一覧の 304（上限に数えない）だけ、ジョブが 1 つ変わった周は 8 回（直下の一覧・そこまでの tree 6 つ・そのジョブの blob）で済む（2026-11-12、#1039）
- アプリの 30 秒ごとの取り直しを Contents API で 1 ファイルずつ読むと、終わった epic も 1 本ごとに 4〜5 回読み、まだ無いファイル（やめた epic の `goal.json` など）は毎回 404 で上限に数えられる
  （2026-11-11 の 14 本で 1 回 132 回・約 5 秒、404 は 10 回）。ETag はメモリーにだけ持つので、起動のたびに全件を 200 で読み、すべて数えられる（iPhone は裏で落とされると開くたびに起動し直す）。
  取り直しは `StateStore.snapshot()` から読み、tree と blob は sha で決まるので Caches のファイルにも持つ（`objectsDirectory`）。変わらなければ直下の一覧の 1 回（304）で済み、起動の直後も直下の一覧の 1 回と変わった分だけになる（2026-11-11、#1031）

## ビルド・テスト

- このリポジトリの CI（Build）は、PR を開いたときの回だけ iOS Simulator の UI テストを流し、25〜40 分かかる（push の回は Unit テストだけで数分）。
  `Build and test on iOS Simulator` の手順が 20 分以上進まなくても、止まっているとは限らない。上限の 45 分までは取り消さずに待つ（2026-11-03、#834）
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
- `swift test --package-path AskHubKit` の全体の実行で、時間に頼るテスト（`LocalLoopRuntimeTests` の `child.pid` を 500ms 以内に書く前提のもの・`XcbStatusTests.returnsEvenIfChildKeepsOutputOpen` の 10 秒）が、
  負荷の高い Mac や CI で揺らいで落ちることがある。`AskHubKit` を変えていない PR なら、ローカルは `--skip LocalLoopRuntimeTests` と `--filter LocalLoopRuntimeTests` に分けて流し、
  CI は `gh run rerun <run-id> --failed` で失敗したジョブだけ流し直す（2026-11-01、Discussion #784）
- Swift Testing のテストも `xcodebuild test -only-testing:AskHubTests/<構造体の名前>`（1 つだけなら `/<構造体の名前>/<メソッド名>()`）で絞って流せる。
  `-quiet` を付けると Swift Testing の結果の行が出ないので、件数を確かめるときは付けずに `Test run with N tests` の行を見る（2026-11-01、Discussion #784）
- 作業ブランチへの push の CI（`build.yml`）は Unit テストを macOS（`Test on macOS`）でしか流さず、iOS Simulator の Unit テストは develop 宛ての PR（epic の最終 PR）で UI テストと一緒に初めて走る。
  macOS と iOS で挙動が違う API（`NSItemProvider` など）を使う Unit テストは、子 PR の CI が通っても最終 PR で落ちることがあるので、手元で iOS Simulator でも `-only-testing:AskHubTests/<構造体の名前>` で流す（2026-11-01、#798）
- iOS の UI テストで、シートを出したまま後ろの View の `frame` を読むと、シートに隠れた部分が切られる（高さが縮み、`midY` がずれる）。
  シートの後ろのカードの位置を確かめるときは、隠れない側の角（`minX`・`minY`）で測る。回転させている View は枠が傾きの分だけ広がるので、幅を持たせて比べる（2026-11-04、リニューアルの UI）
- UI テストで、1 本目の指で引いている途中に 2 本目を時間差で置く操作は、XCTest の内部の `XCPointerEventPath`（`initForTouchAtPoint:offset:`・`moveToPoint:atOffset:`・`liftUpAtOffset:`）を
  `XCSynthesizedEventRecord`（`initWithName:interfaceOrientation:`・`addPointerEventPath:`・`synthesizeWithError:`）にまとめて合成できる（WebDriverAgent と同じ方法。Swift からは `method(for:)` の IMP を呼ぶ）。
  ただし「2 本目を置いたまま 1 本目を先に離す」と、Simulator 側で 1 本目の `UITouch` が 2 本目の位置へ滑っていく（同じ `UITouch` に 2 回目の `began` が来る）ので、この場面は実機で確かめる。
  リポジトリには置かない（内部の API なので Xcode の更新で動かなくなりうる）（2026-11-04、スワイプの手触り）
- アプリにリンクする AskHubKit のライブラリ（AskHubClient など）は iOS でもビルドされるが、`swift test --package-path AskHubKit` は macOS でしか流さないので、
  iOS で使えない API（`FileManager.default.homeDirectoryForCurrentUser` など）が入っても気づかず、アプリの iOS のビルドで初めて落ちる。
  ホームのフォルダは `URL.homeDirectory` で求める（2026-11-07、状態リポジトリへのつなぎ込み）
- UI テストで `-demoScenario` を付けずに起動すると、設定の既定（状態リポジトリ）で動く。デモのデータで動かしつつ場面を設定で変えるテストは、
  `-dataSource demo` を付ける（2026-11-07、状態リポジトリへのつなぎ込み）
- CI（macos-26-arm64）の `swift test --package-path AskHubKit` では、負荷でテストが一律に遅れることがあり、その幅が 5 秒（#699）から 10.9 秒（2026-11-05）に広がった。
  `ContinuousClock.now - start < 上限` で「子プロセスを待たずに戻った」ことを確かめるテストは、上限を 30 秒、待たないはずの子プロセスの `sleep` を 60 秒にそろえている（`LocalLoopRuntimeTests.returnLimit`・`XcbStatusTests.returnLimit`）。
  同じ形のテストを足すときは、上限をふだんの所要時間でなく CI の遅れに合わせ、`sleep` は上限の倍にする。成功を期待するコマンドの `timeout` も上限より短くしない
- テストの中で作ったばかりのスクリプト（`#!/bin/sh` の実行ファイル）は、最初の起動に 0.15〜0.5 秒かかる（2 回目からは速い）。
  `XcbStatusTests` は時間切れを 200ms にしていたため、スクリプトが子プロセスを起動する前に止めてしまい、確かめたいこと（子プロセスがパイプを持ち続けても返る）を確かめられていなかった。
  `/bin/sh` でも、`swift test` で全体を並べて流すと準備（子プロセスの起動・`trap` の設定）が 500ms に間に合わないことがある（`LocalLoopRuntimeTests` の `child.pid` を読むテストが落ちていた）。
  時間切れで止める前にスクリプトに準備させたいテストは、時間切れを数秒にし（`LocalLoopRuntimeTests.setupTimeout` は 3 秒）、実装を一時的に壊して（読み切りの上限を伸ばすなど）テストが落ちることを確かめる。
  子プロセスを残すテストは、スクリプトに子プロセスの PID を `child.pid` に書かせ、残っていることを確かめてから `defer` で止める（2026-11-06）
- 状態リポジトリにつないだときの画面（`StateClientService` が出すもの）は、デモの場面では撮れない。PR のスクショは、`StateConnection.makeService()` を
  一時的に `InMemoryStateStore`（見本のファイル）とソフトウェアの鍵の `StateClientService` に差し替えて撮る（コミットしない）。Before は base を `git worktree add --detach` で
  別の場所に取り出して同じ差し替えを当てると、同じデータで比べられる。`-demoOpen epic:<id>` は状態リポジトリのときも効く（2026-11-07、#879）
- 開発者モードが無効（`DevToolsSecurity -status` が disabled）の Mac では、ターミナルから流しても macOS の `xcodebuild test` がテストのホストを起動できずに止まることがある
  （`Testing started completed` の後に何も出ない）。iOS Simulator の `-only-testing:AskHubTests` は通るので、手元の Unit テストはそちらで流す。
  Xcode 27.1 の `xcodebuild test` は、テストが終わって `Executed N tests` を出した後に戻らないことがあるので、結果はログの `Executed` と `Test Case … failed` の行で判断する（2026-11-07、#879）
- 結果のバンドルは `xcrun xcresulttool get build-results` と `get test-results summary`（`--compact` で 1 行の JSON）で読める。
  `build-results` の `errors` の `sourceURL`（`file://…#…&StartingLineNumber=12&…`）の行は 0 から数えるので、エディタの行は +1 する。
  テストの操作でビルドが失敗すると、`errors` に場所の無い「Testing cancelled because the build failed.」も入る。
  `test-results summary` の `devicesAndConfigurations` は、JSON Schema（0.4.0）ではオブジェクトだが実際は配列で返る（Xcode 27.1）ので、使う欄だけを読む（2026-11-07、#886）
- `xcrun simctl shutdown` は、止まっている Simulator には終了コード 149（`Unable to shutdown device in current state: Shutdown`）で失敗する。
  `erase`・`delete` の前に止めるときは、この失敗を成功とみなす（2026-11-07、#886）
- 人や Claude のセッションが、画面の確認用に `askhub-` で始まる名前の Simulator（`askhub-anim-a` など）を作っていることがある。
  ワーカー（`AskHubBuild` の `SimulatorPool`）が作って消すのは `askhub-worker-<枠>-…` の形の名前だけなので、手で作る Simulator にはこの形の名前を付けない（2026-11-07、#886）
- UI テストの起動引数（`-demoReactionDelay 0` など）で渡した値は、UserDefaults に文字列で入るので `object(forKey:) as? Double` は nil になる
  （`-demoReactionDelay 0` が効かず、既定の 4 秒のまま動いていた）。数値は `double(forKey:)` で読む（`-demoSendDelay`）。
  値が無いことと 0 を分けたいときは、`object(forKey:) != nil` で確かめてから `double(forKey:)` を使う（2026-11-07、#896）
- `xcodebuild test -resultBundlePath` が `Executed N tests` の後に戻らず、`.xcresult` に `Info.plist` ができない（`xcresulttool export attachments` が読めない）ときも、
  UI テストで撮ったスクショ（`XCTAttachment`）は `<bundle>.xcresult/Data/data.0~…` に PNG で入っている。`file` で PNG を探し、撮った順は更新時刻の順で並べる（2026-11-07、#896）

- ワーカーの git（`GitRepositoryWorkspace`）は手元のパスの remote を断る（`GIT_CONFIG_*` の `protocol.file.allow=never`）。本物の git で確かめるテストは、
  git を `exec /usr/bin/git -c protocol.file.allow=always "$@"` の包みに差し替え（コマンドラインの `-c` は環境変数の設定より強い）、clone を先に作っておく（`update` は fetch だけになる）。
  origin は手元のベアのリポジトリにする（`TaskGitTests`。2026-11-07）
- `/bin/sh` のスクリプトが `&` で後ろに回した子プロセスは SIGINT を無視する（ジョブ制御の無いシェルの決まり）。`ProcessCommandRunner` で止めると、
  子は SIGINT では止まらず、`interruptGrace`（10 秒）の後の SIGTERM で止まる。子孫が止まることを確かめるテストは、それだけ時間がかかる（2026-11-07、`EpicBuildServiceTests`）
- macOS 27 の上の Xcode 26.6 では、Simulator でテストを流すと「DTServiceHubClient failed to bless service hub」「The test runner hung before establishing connection.」で止まる（ビルドは通る）。開発者ツールの許可（`DevToolsSecurity`・`_developer`）は関係なかった。Xcode を 27 系に上げると直った（2026-11-08、Mac mini）
- iOS 27.1 の Simulator のランタイム（24A94425）は、iPhone Duo だけに対応する。iPhone 17 Pro などは iOS 27.0（24A434）のランタイムで動く。`xcodebuild -downloadPlatform iOS` は 27.1 と 27.0 を続けて取る。版を決めずに「SDK と同じか古い最新」を選ぶと 27.1 になり、機種を作れない（`simctl create` が「Incompatible device」）。機種に対応するランタイムのうち最新を選ぶ（`supportedDeviceTypes`）
- Xcode を上げた後、前の版の `CoreSimulatorService` が動いたままだと、新しいランタイムが「unavailable, liblaunch_sim.dylib could not be opened」になる。起動中の端末が無いときに `killall -9 com.apple.CoreSimulator.CoreSimulatorService` で動き直させる
- 状態ファイルの見本（テストの JSON）に形の違う値（`keyId` が 43 文字でない・ULID の形が違うなど）が 1 つでもあると、`StateReader` はそのファイルごと読まずに
  `sourceFailures` に入れるだけで、組み立ては続く（判断の一覧が丸ごと空になり、テストには「カードが 0 枚」という食い違いだけが出る）。
  見本のファイルを使うテストでは、`snapshot.sourceFailures.isEmpty` も確かめる（2026-11-08、最終 PR の確認のつなぎ込み）
- 意図の番号（ULID）が送った順に大きくなるのは、同じ `IntentSender`（中の `NonceSequence`）で送ったときだけ。送るたびに作り直すと、同じミリ秒に送った意図の大小は乱数で決まる
  （テストの固定の時計で、判断への答えより承認の番号が小さくなることがあった）。司令塔は番号の順に処理するので、順が要る意図は 1 つの `IntentSender` で送る（2026-11-08、最終 PR の確認のつなぎ込み）
- 司令塔のテストで人の意図を続けて置くとき、`nonce` を同じ時刻の `ULID.generate(at:)` で作ると、時刻の部分が同じでランダムな部分の順に処理され、置いた順にならない。
  `now.addingTimeInterval(0.001 * n)` でずらしても、浮動小数の誤差でミリ秒が切り捨てられて同じ時刻になることがある（`1_793_757_600.001` が `…600000` ミリ秒になる）。秒単位でずらす（`FinalFlowFixture.place`。2026-11-08、#911）
- Simulator に外から入れたタップ（Claude Code の Simulator の操作・`simctl` 系）では、ツールバーの `Menu` を開いて中の `Button` は押せるが、`Menu` の中の `Menu`（サブメニュー）は押しても開かない（長押し・なぞりでも開かなかった）。
  PR のスクショでサブメニューの中身を撮るときは、同じ `Menu` を直接開ける画面（「対処が要ります」の `HandOverMenu` など）から撮る（2026-11-08、#935）
- macOS のアプリに push の entitlement（`com.apple.developer.aps-environment`）を付けると、`CODE_SIGN_IDENTITY=-` のアドホック署名でも
  「"AskHub" requires a provisioning profile」でビルドが止まる（profile が要る entitlement）。自動の署名でも、その App ID の Mac 用の profile が
  手元に無ければ「No profiles for 'jp.shilokuma.AskHub' were found」で止まる。アドホック署名の流れ（CI・ワーカー・xcb・スクショ・archive）は
  どれも `CODE_SIGN_STYLE=Manual` を渡すので、`CODE_SIGN_ENTITLEMENTS[sdk=macosx*] = $(ASKHUB_MACOS_ENTITLEMENTS_$(CODE_SIGN_STYLE))` で自動の署名のときだけ付けている。
  iOS の Simulator 向けのビルドは profile が要らないので、entitlement をいつも付けてよい（2026-11-09、通知のアプリ側）
- Export（`xcodebuild -exportArchive`）は、archive の実行ファイルの署名にある entitlement だけを引き継いで署名し直す。profile にあっても足さず、値だけを profile に合わせる
  （archive の `aps-environment = production` が、development の書き出しでは `development` になった）。`CODE_SIGNING_ALLOWED=NO` の iOS の archive からは `aps-environment` の無い IPA になる。
  push の entitlement があると、iOS のアドホック署名の archive は `CODE_SIGN_STYLE=Manual` では「requires a provisioning profile」、Xcode Cloud と同じ
  `CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Automatic` では「has entitlements that require signing with a development certificate」で止まる。
  archive の後に `codesign --force --sign - --entitlements` で .app に埋め込めば、Export が引き継ぐ（`Tools/embed_archive_entitlements.py`）。
  API キーで archive を自動の署名にすると、キーチェーンが空の CI では実行のたびに「Apple Development: Created via API」の証明書が作られて残るので使わない（2026-11-09、`_archive.yml`）

- LicenseList（cybozu）のビルドのプラグイン `PrepareLicenseList` は、`URL.path()`（空白を `%20` にした形）で `SourcePackages` の有無を調べるので、DerivedData のパスに空白があると見つけられず `SourcePackages not found` で止まる。CI のように標準の DerivedData（空白なし）なら通る。ワーカーの DerivedData とリポジトリの写しは、空白の無い `~/Library/Developer/AskHub/<役割>/` に置く（2026-11-09、prime-pick-ios の試運転）
- 署名済みの .app を `codesign --force --sign - --entitlements …` で署名し直すと、元の署名のフラグが消える（macOS のアドホック署名の archive の `flags=0x10002(adhoc,runtime)` が `0x2(adhoc)` になり、Hardened Runtime が外れる）。
  `--preserve-metadata=identifier,flags` を付ければ残る。macOS の archive に push の entitlement を足すときは、`codesign -d --entitlements - --xml` で読んだ元の entitlement（sandbox など）に足して渡す（上書きすると消える）。
  Export した macOS の pkg の中の .app は、`pkgutil --expand-full <pkg> <まだ無いフォルダ>` で取り出して `codesign -d` で読める（2026-11-09、Mac 版の TestFlight）

- ワーカーが Simulator 向けにビルドしたアプリの場所と Bundle ID は、`xcodebuild -showBuildSettings -json`（ビルドと同じ `-destination id=<UDID>`・`-derivedDataPath`）の、
  `WRAPPER_EXTENSION` が `app` で `PRODUCT_TYPE` が `com.apple.product-type.application` の項目の `TARGET_BUILD_DIR`・`FULL_PRODUCT_NAME`・`PRODUCT_BUNDLE_IDENTIFIER` で読める
  （テストのターゲットも並ぶので、種類で選ぶ。2026-11-09、`ScreenshotCapturer`）
- アプリのターゲットは SwiftLint のビルドのプラグインを通すので、PR のスクショのために `AskHub/` に一時的に置いたファイルでも、Lint の違反（行の長さなど）でビルドが止まる。
  一時的なファイルの先頭に `// swiftlint:disable line_length` などを書く（コミットしない。2026-11-09、判断のカードのスクショ）
- デモのデータの文には、今の時刻から作るもの（「22:40 に確かめました」「次は 22:55」など）がある。判断のカードの Before と After を別の時刻に撮ると、その文も変わって写る（2026-11-09、`.askhub/screenshot-scenes.json`）
- Swift Testing はテストを並べて流すので、一時的なフォルダの名前をジョブの id など見本で同じになる値だけで決めると、ほかのテストが消してしまう。名前に `UUID()` を足す（2026-11-09、`CaptureScreenshotsRunnerTests`）
- iOS 26 の `safeAreaBar(edge: .bottom)` の帯（マージのボタンなど）の下に一覧の行が隠れていても、UI テストの `exists` は true のままで、`tap()` は帯のほうに当たる
  （確認のダイアログが出ず、次の待ちで落ちる）。帯の近くの行のボタンを押すときは、一覧の終わりまで `swipeUp()` してから押す（2026-11-10、`testAcceptAllShowsDoneAtOnceAndSyncsLater`）
- Xcode 26.6 の `xcodebuild test`（iOS Simulator の UI テスト・`-resultBundlePath` あり）も、`Executed N tests` を出した後に戻らないことがあった。`.xcresult` は `Data` と `Staging` だけで、
  UI テストの画面の録画が `Data/data.0~…` に QuickTime で入る。結果はログの `Test Case … passed/failed` の行で判断して止める（2026-11-10）
- Mac 版のビルドが TestFlight にあっても、内部テストのグループの「iPhone と iPad の App を Apple シリコン搭載の Mac でテスト」がオンだと、Apple シリコンの Mac の TestFlight からは iPad 版が入った。
  iPad 版は `#if os(iOS)` の側で動くので、メニューバーに「設定…」が無く、端末の鍵のラベル（`UIDevice.current.model`）が `iPad` になる。グループの設定をオフにして入れ直すと Mac 版が入った（2026-11-10、個人の Mac での確認）
- 設定の画面（シートで開く `AppSettingsView`）は起動引数で開けない。Simulator を操作できない（タップできない）ときは、撮影用の取り出しだけに
  `AppNavigator.isShowingSettings = true` と、撮りたい節を `Form` の先頭に移す変更を当ててビルドし、`xcrun simctl io <udid> screenshot` で撮る（コミットしない）。
  Before と After で同じ Simulator を使えば、Keychain の端末の鍵も同じものが出る。UserDefaults の値は `simctl spawn <udid> defaults write <Bundle ID> <キー> -string '…'` で入れる
  （`-string` を付けないと、`'` や括弧を含む値は「Could not parse」で入らない）（2026-11-10、端末の名前の欄）
- 各リポジトリの CI は Xcode 26.6 で固定しているが、AskHub のワーカー（Mac mini）は Xcode 27.1 でビルドする。shariverse/dokogacha-app-ios は、CI では通るのに 27.1 では
  `DGDashedLine.swift` の `DashedLineShape: Shape` が `#ConformanceIsolation`（既定の隔離が MainActor の型の `Shape` への準拠）で落ちる。既存のリポジトリを AskHub に移す前に、
  ワーカーと同じ Xcode で `repo.json` の `build` と同じ `xcodebuild build-for-testing` を流して確かめる（2026-11-09、shariverse の移行の調査）
- 司令塔とワーカーは LaunchAgent で動き、ビルドの子には PATH を `/usr/bin:/bin:/usr/sbin:/sbin` だけで渡すので、Homebrew の道具（`xcodegen` など）は名前では見つからない。
  `BuildTools.toolDirectories`（`/opt/homebrew/bin`・`/usr/local/bin`・`~/.local/bin`）から絶対パスで探して起動する。XcodeGen の `Spec validation error:` は理由を次の行に書くので、
  出力の抜粋をエラーの行だけに絞ると理由が落ちる。XcodeGen（2.46）は環境変数 `USER` が無いと「Couldn't find current username」で止まる（`LOGNAME` だけでは足りない）ので、
  環境変数を作り直すときは `USER` を渡す（2026-11-10、`build.xcode.generate`）
- `AskHubUITestsLaunchTests` の雛形（`runsForEachTargetApplicationUIConfiguration` が true）は、起動テストを構成（縦横・ライトダーク）の数だけ流し、XCTest が端末の向きを変える。
  CI の Simulator では、向きの変更の確認を 60 秒待って「Failed to set device orientation」で落ちることがあった。起動テストは false にして今の向きで 1 回だけ流す（2026-11-10、#1006）
- 新しく起動した Simulator では、`XCUIDevice.shared.orientation` は `.portrait` を返さない（`!= .portrait` で確かめると、縦向きでも向きを設定し直す）。横向きの後は `.landscapeRight` などが返る。
  縦向きに戻すのは `orientation.isLandscape` のときだけにする（2026-11-10、#1006）
- CI（GitHub Actions の macOS ランナー）は `Apple M2 Pro (Virtual)` の 5 コアで、Simulator を起動した後の数分は、ウィジェットやデーモンが次々に動いて
  load average が 500 を超え、CPU の空きは 0%、メモリの空きは数百 MB になる。この間、アプリと UI テストの問い合わせが数秒〜40 秒止まることがあり、
  同じテストでも、止まるかどうか・どれだけ止まるかは回ごとに違う（単独で流しても、起動テストの後に流しても、止まらない回があった）。
  UI テストで状態の変化を待つ時間は、手元の所要時間の数倍ではなく CI の止まりを見込んで長くとる（印が消えるのを待つ `ClientUITests.syncTimeout` は 90 秒）。
  通った回のログでも、`Checking existence of …` の行の間が 20 秒以上空いていれば同じ止まりが起きている（30 秒の待ちに収まったかどうかで結果が変わっていた）（2026-11-10、#1006）
- CI の `TestResults.xcresult`（成果物）には UI テストごとの画面の録画（`kXCTAttachmentScreenRecording` の mp4）が入り、`xcrun xcresulttool export attachments --path TestResults.xcresult --output-path <出力先のフォルダ> --test-id "<クラス>/<メソッド>()"` で取り出せる（`manifest.json` に添付の名前と時刻が入る）。
  録画は画面が変わったときだけコマを足すので、コマの時刻の間（ステータスバーの時計も止まる）で止まった時間が分かる。ffmpeg の無い Mac でも、`AVAssetImageGenerator` の小さな Swift のスクリプトで
  指定した秒のコマを JPEG にできる（返る実際の時刻を見ると、どこでコマが止まったかが分かる）（2026-11-10、#1006）
- UI テストの最中に Simulator のアプリへ `sample` を 1 秒ごとに当てると、読む間アプリを止めるので所要時間が数倍になり、ほかのテストまで落ちる。CI で止まりを調べるときに時間を比べる回では `sample` を当てない（2026-11-10、#1006）
- 判断のカードの Before と After で時刻の文がずれる件は、デモの時計を止める起動引数 `-demoClock <ISO 8601>`（`DemoScenario.clockKey`）を撮れる画面の一覧の全部の画面に渡してそろえる。止めた時計では機械の反応が起きないので、撮影のほかには使わない（2026-11-10、`.askhub/screenshot-scenes.json`）
- ワーカーの枠の Simulator は、中の状態が壊れて、入れたアプリやテストの実行役を起動できなくなることがある。結果のバンドルのエラーと落ちたテストが
  `Failed to install or launch the test runner`・`Simulator device failed to launch <Bundle ID>. No such process`・
  `The request was denied by service delegate (SBMainWorkspace) for reason: NotFound ("Unknown application…")` になり、`xcrun simctl shutdown` で止めてから流し直すと通った
  （2026-11-10 08:46Z、Mac mini の Xcode 27.1・iOS 27.0）。`EpicBuilder` は、結果のバンドルのエラーと落ちたテストがすべて起動の失敗のときだけ、Simulator を消去して起動し直し、1 回だけ流し直す。
  手元では、`xcrun simctl spawn <UDID> launchctl bootout system/com.apple.SpringBoard` で同じ「起動できない」状態を作れ（`Simulator device failed to launch`。止めて起動し直すと戻る）、
  `LiveBuildTests.recoversWhenTheSimulatorCannotLaunchApps` がこれで流し直しを確かめる（#1013）
- 常時オンの Mac の `xcode-select` が古い Xcode（Xcode 26.6・iOS SDK 26.5）に切り替わると、iOS 27.0 の Simulator で `Simulator device failed to launch … No such process`・
  `The test runner hung before establishing connection.`（出力に `DTServiceHubClient failed to bless service hub`）になり、同じ枠を使うジョブが続けて止まった（2026-11-10 17:3xZ の 2 回。
  `sudo xcode-select -s /Applications/Xcode.app` で 27.1 に戻した。切り替えた時刻は `/var/db/xcode_select_link` の時刻で分かる）。Simulator を起動し直しても直らないので、
  `SimulatorPool.prepare` は、使う Xcode の SDK より新しいランタイムの Simulator を作らずに断る（#1013）
- `/usr/bin/xcrun` は、環境変数 `DEVELOPER_DIR` があれば `xcode-select` より優先し、その下の `usr/bin/xcrun` に渡す。`Xcode.app` のパスも受け付ける（`Contents/Developer` を足す）。
  フォルダが無いと「missing DEVELOPER_DIR path」、`usr/bin/xcrun` が無いと「invalid DEVELOPER_DIR path … missing xcrun」で止まる。ワーカーは設定の `xcode` を `DEVELOPER_DIR` で渡し、
  流す前に `usr/bin/xcodebuild` があるかを確かめる（`BuildTools.developerDirectoryProblem`）。一時フォルダに `usr/bin/xcrun`（`exec "$(dirname "$0")/$1"` で道具に渡すスクリプト）と
  `usr/bin/xcodebuild` を置いた偽の Xcode でも本物の `xcrun` から動くので、テストでは偽の Xcode で「xcode-select と違う Xcode が使われる」ことを確かめる（`FakeXcode`）（2026-11-11、#1015）
- `askhub-commander`・`askhub-worker` の置き場所（`MachinePaths`）は `FileManager.default.homeDirectoryForCurrentUser` から作り、環境変数 `HOME` を差し替えても本当のホームフォルダの
  `~/Library/Application Support/AskHub/<役割>/config.json` を読み書きする。手元で設定を書き換えるコマンドを試すときは、実行ファイルを流さず、テストで
  `MachineCommandLine(role:executable:home:)` に一時フォルダを渡す。失敗の道は `exit` するので、設定の `kind` と役割が合わない（常時オンの設定をワーカーで読む）とテストのプロセスごと終わる（2026-11-11、#1015）
- Icon Composer の `.icon` を PNG に書き出せるのは `Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`（`--export-image --platform iOS --rendition Default --width --height --scale`）。
  `xcrun ictool` が見つける `Contents/Developer/usr/bin/ictool` は Asset Catalog 用の別のもので、`--export-image` を「Unknown argument」（actool の形の plist）で断る。
  書き出した PNG は角が透明の角丸で、iOS 26 のガラスの質感が入る（256px で 200 KB ほど）（2026-11-12、#1033）
- `git ls-tree -r -d <コミット>` は tree だけを下の階層まで並べる（ファイルを並べないので、大きなリポジトリでも出力が小さい）。`-z` ならパスを引用符で囲まずに NUL で区切る。
  `--filter=blob:none` の partial clone でも tree は手元にあるので、`ls-tree -r -d` は通信しない。`ls-tree -l`（大きさ）と `cat-file blob` は、無い blob をその場で 1 つずつ取りに行く（2026-11-12、#1033）
- `xcrun devicectl device capture screenshot --device <名前か UDID> --destination <PNG>` で、つないだ実機の画面を撮れる（Xcode 26.6）（2026-11-12、#1033）
- UI テストが変えた Simulator の端末の向き（`XCUIDevice.shared.orientation`）は、Simulator を起動している間ずっと残り、次の `xcodebuild test` は横向きのまま始まる
  （ログに `Interface orientation changed to Landscape Right`）。`simctl` には向きを読む・変えるコマンドが無く（Xcode 26.6・27.1）、`simctl io <UDID> screenshot` も横向きのときに縦長の画像（1206×2622）を返すので、
  外から向きを確かめられない。`simctl shutdown` → `simctl bootstatus <UDID> -b` で縦向きに戻る（手元の iOS 26.5 で 13〜22 秒）。外観（`simctl ui <UDID> appearance dark`）は起動し直しても戻らない。
  ワーカーはテストと撮影の前に、起動していた枠の Simulator を止めてから起動し直す（2026-11-11、#1027）
- Simulator の外観（`simctl ui <UDID> appearance`）は、止めて起動し直してもダークのまま残り、消去（`simctl erase`）するとライトに戻る。止まっている Simulator では、読むと `unknown`（終了コード 0）、
  変えると `Unable to lookup in current state: Shutdown`（終了コード 149）になるので、起動してから読み書きする。visionOS 26.5 の Simulator も `light`・`dark` を読み書きできる（`unsupported` ではない）。
  読み書きの時間は `simctl getenv` などほかの `simctl` 1 回と同じくらい（手元の Xcode 26.6・iOS 26.5）。ワーカーはテストと撮影の前に、起動し直した後で外観を読み、`dark` ならライトに戻す（2026-11-12、#1045）
- SSH で入った Mac（macOS 27 の Mac mini など）では、画面収録の許可が無く `screencapture` が「could not create image from display」で撮れない。
  アプリが自分の窓を撮るなら許可は要らないので、DEBUG の起動引数 `-demoSnapshot <名前>`（`-demoWindowSize 1240x820`・`-demoAppearance dark`・`-demoPress "ボタンの名前"`・`-demoSettings YES`）で
  コンテナの tmp（`~/Library/Containers/jp.shilokuma.AskHub/Data/tmp/`）に窓ごとの PNG を書く（`DemoWindowSnapshot`）。ビルドした .app を `rsync` で送り、`ssh <Mac> open -g -n <.app> --args …` で起動する。
  `cacheDisplay(in:to:)` で描くと、NavigationSplitView のサイドバーと詳細の列が白や黒に抜けるので、`CGWindowListCreateImage`（macOS 15 の SDK で使えないので `dlsym` で引く）で撮る。
  macOS 27 では支援技術がつながるまで SwiftUI がアクセシビリティの木を作らず、アプリの中から名前でボタンを探せないので、`NSApp` に `AXManualAccessibility` を立てる（2026-11-12、Mac の UI の直し）
- `xcodebuild test` は、既定（`-collect-test-diagnostics on-failure`）では、テストが落ちると、テストの後に `simctl diagnose -l -b --timeout=600 --log-option=--last --log-option=2m --output=<結果のバンドル>/Staging/1_Test/Diagnostics/simctl_diagnostics` を流す。
  手元（Xcode 26.6・iOS 26.5）では中のログの取り出しが終わらず、`Failure collecting diagnostics from simulator: Timed out after 600.0 seconds` まで 10 分止まった（結果のバンドルも 5.5MB → 46MB。Mac の DiagnosticReports の写しなどが入る）。
  集めるのは、記録された issue があるか、テストの実行役がエラーで終わったときだけ（IDEFoundation の `IDETestRunSession` の `_atLeastOneTestFailed`・`_atLeastOneTestRunnerFailedWithError`。Xcode 26.6・27.1 で同じ）で、
  通ったテストでは、作ったばかりの Simulator の 1 回目でも流れなかった。`-collect-test-diagnostics never` なら止まらず、`test-results summary` の `testFailures` の文と、テストごとの添付
  （クラッシュのレポート `.ips`・画面の録画）は残る。ワーカー（`XcodeBuildRunner`）はテストのときにいつも `never` を渡す。止まりを調べるときは、`ps` で `simctl diagnose` の子を探し、
  xcodebuild の出力の `IDETestOperationsObserverDebug: Failure collecting diagnostics` の行を見る（2026-11-12、#1047）
- Release の構成を開発用の署名（`xcodebuild -configuration Release -allowProvisioningUpdates` の自動の署名）で実機向けにビルドすると、entitlement のファイルの `aps-environment` が `production` でも、
  Xcode は profile に合わせて `development` で署名する（Info.plist に入れたビルド設定の値は `production` のまま）。APNs は署名の環境のトークンを返すので、ビルド設定から環境を決めると
  development のトークンを production の宛先に書き、`400 BadDeviceToken` で断られる。環境は、iOS は埋め込みの `embedded.mobileprovision`（CMS で包んだ XML の plist）の `Entitlements`、
  macOS は `SecTaskCopyValueForEntitlement` で読む（iOS では使えない）。同じ端末でも、開発用の署名の版と TestFlight の版でトークンが違う。
  ビルドした .app の値は、`codesign -d --entitlements - --xml <.app>` と `security cms -D -i <.app>/embedded.mobileprovision` で確かめられる（2026-11-12、#1059）

## Keychain

- macOS で `kSecUseDataProtectionKeychain` を使うには、provisioning profile で許可された entitlement
  （`keychain-access-groups` / `application-identifier`）付きの署名が要る（TN3137）。無いと `errSecMissingEntitlement`（-34018）になる。
  付けない場合は従来の Keychain になり、`kSecAttrAccessible`（`AfterFirstUnlock` など）は効かない
- Apple シリコンの Mac の Simulator でも `SecureEnclave.isAvailable` は true で、Secure Enclave の鍵を作れる
  （`DeviceSigningKey` の保存場所が Simulator でも `secureEnclave` になる）（2026-11-07、状態リポジトリへのつなぎ込み）
- 署名の無い（ad-hoc の）司令塔を入れ替えると、Keychain の項目の「常に許可」が別のプログラムとみなされて効かず、入れ替えのたびに確認が出る。Developer ID と同じ識別子で署名し続ければ、一度の「常に許可」が入れ替えた後も続く（2026-11-08、`scripts/commander/deploy.sh`）
- ssh のセッションからは、ログインキーチェーンの署名の鍵を使えない。`codesign` が `errSecInternalComponent` で止まり、`launchctl asuser` も「Could not switch to audit session」で使えない。遠隔で署名するときは、ログイン中のセッションの LaunchAgent に依頼のファイルを拾わせて署名させる（2026-11-08、`jp.shilokuma.askhub.deploy`）
- 同じ Mac で、TestFlight の iPad 版を消して Mac 版を入れ直しても、「この端末の鍵」（Secure Enclave）は同じ公開鍵が出た（同じ Bundle ID・チーム）。
  Mac 版で登録した後、Mac 版の「登録を確かめ直す」で登録済みになった（iPad 版では登録していない。2026-11-10）
- develop からビルドし直した非常口（`askhub`）は、署名が変わるので、初回に Keychain（サービス `jp.shilokuma.AskHub.cli`）の項目を読む確認が出る。許可すれば続けて使える
  （司令塔と同じく、アドホック署名のビルドは別のプログラムとみなされる。2026-11-10、shariverse の移行）

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
- Swift Testing の `#expect(items.allSatisfy(\.isDone))` のように、キーパスを渡した `allSatisfy` などの rethrows の呼び出しをマクロの中に書くと、
  展開の後に「call can throw, but it is not marked with 'try'」でビルドが止まる。結果を `let` で受けてから `#expect` に渡す（2026-11-03、リニューアルの UI）

- `NSRegularExpression`（ICU）の `$` は、複数行の指定が無くても、末尾の改行の前で合う（`^[a-z/]+$` が `"a/b\n"` に合う）。Python でも同じことを確かめた。Java の `Pattern` も文書上は同じで、ECMAScript だけが合わない（Kotlin のクライアントの検証で効く）。
  JSON Schema の `pattern` で値を区切るときは、長さの決まった値は `maxLength` を足し、そうでない値は `"not": { "pattern": "\\n" }` で改行を弾く（`protocol/schemas`。2026-11-03、#835）
- 型つきの throws（`throws(E)`）の関数に閉包を渡すときは、閉包の型が推論されず `any Error` になる。`{ () async throws(E) -> T in … }` と書き、
  閉包の中の `do` も `do throws(E) { … }` と書く（書かないと `catch` の `error` が `any Error` になり、`.case(error)` に渡せない）（2026-11-03、`StateFileStore`）
- actor のメソッドから、閉包を受け取る nonisolated の async の関数（失敗の型を変えるだけの包みなど）を呼ぶと、閉包が actor の外へ送られるとみなされ、
  「sending value of non-Sendable type … risks causing data races」になる。包みを `static func f<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws(E) -> T)` にすると、
  呼んだ側の isolation のまま動くので通る。インスタンスメソッドに isolated の引数を付けると `nonisolated` にできない（「instance method with 'isolated' parameter cannot be 'nonisolated'」）ので `static` にする（2026-11-07、`DiscussionMirror`）
- Swift Testing の `#require` の引数の中に `#require` を入れる（`try #require(try JSONSerialization.jsonObject(with: #require(data)) as? [String: Any])`）と、
  「recursive expansion of macro 'require(_:_:sourceLocation:)'」でテストのビルドが止まる。内側の `#require` を `let` で受けてから外側に渡す（2026-11-07、`APNsSenderTests`）
- 開きと閉じがある文字列（HTML コメントの `<!--` と `-->` など）の閉じを本文の先頭から探すと、`<!-->`・`<!--->` のように閉じが開きと重なる本文で開きの中の位置が返り、
  `index(startIndex, offsetBy: 開きの長さ)..<閉じ.lowerBound` の下の端が上の端より大きくなって「Range requires lowerBound <= upperBound」で落ちる。
  public のリポジトリでは誰でもこうした本文を書けるので、閉じは開きの後ろ（`dropFirst(開きの長さ)` の Substring）から探す。目印の先頭のコメントは `MarkerComment.leadingCommentContent` で読む（2026-11-03、#844）
- `URL.resourceValues(forKeys:)` は、読んだ値を URL ごとに覚えていて、同じ URL のまま読み直すと前の値を返す（`volumeAvailableCapacityForImportantUsage` も）。常駐するプロセスで空き容量を何度も測るときは、読む前に `removeAllCachedResourceValues()` を呼ぶ（2 GB 書いた後も同じ URL では値が変わらず、キャッシュを消すと 2 GB 減った。Mac mini の司令塔が起動したときの空き容量を書き続けていた。2026-11-08）

- `OSAllocatedUnfairLock.withLock` は typed throws を通さない（`withLock { state throws(E) in … }` は「thrown expression type 'any Error' cannot be converted to error type 'E'」）。
  閉包で `Result<T, E>` を返し、外で `try result.get()` する（2026-11-07、タスクのジョブのテストの偽物）
- ローカル変数をメソッドと同じ名前にすると、その変数の初期化の式の中のメソッドの呼び出しも変数を指し、「cannot call value of non-function type '[Any]'」でビルドが落ちる
  （`let humanTasks = goal.map { humanTasks($0, epic: file) }`。Xcode 26.6）。アプリのコードは `swift test --package-path AskHubKit` では見つからず、アプリのビルドで初めて落ちるので、変数は別の名前にする（2026-11-08、人がする作業）
- `UNUserNotificationCenterDelegate` の `didReceive`（`willPresent` も）を async の版で書くと、Swift が橋渡しで作る Task の中で
  関数を抜けた後に、完了ハンドラが協調スレッドから呼ばれる。UIKit は完了ハンドラの中で主スレッドかを確かめるので、通知を押したときに
  `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]` の NSAssertionHandler で落ちる（`nonisolated` の async の版で起きた）。
  完了ハンドラの版にして、呼ばれたその場（主スレッド）で呼び、画面の更新だけを `Task { @MainActor in … }` に渡す（2026-11-09、通知を押すと落ちた）
- 起動引数（`-key value`）の値は、UserDefaults に文字列で入る。`defaults.object(forKey:) as? Double` は nil になる（数として読むなら `defaults.string(forKey:).flatMap(Double.init)` か `double(forKey:)`）。
  デモの `-demoReactionDelay` はこの読み方のため効いておらず、いつも既定の 4 秒になっている（2026-11-09、反映中の UI で `-demoReceiptDelay` を足して気づいた）
- `-demoReactionDelay` も文字列から読むように直し（デモの秒数はすべて `DemoScenario.seconds(forKey:in:)` で読む）、UI テストでは機械の反応と司令塔の受け取り（既定は反応の半分）がすぐ起きるようになった。
  送った直後の読み直しで受け付けが見つかるので、送れたことの帯（「…を送りました」）はすぐ「…を受け付けました」に替わる。受け取る前の画面を UI テストで見るときは、
  `-demoReceiptDelay` で受け取りだけを遅らせる（受け取りが遅いと知らせる 3 分より短くする。`testRequestShowsProgressAndConfirmsDuplicate`）（2026-11-09、#954）
- アプリのターゲットは MainActor 既定なので、`static func` をそのまま関数値として渡すと（`optional.flatMap(normalizedLabel)` など）、
  「converting function value of type '@MainActor (String) -> String?' to '(String) -> String?' loses global actor 'MainActor'」でビルドが落ちる。
  状態を持たない関数は `nonisolated` にする（その中で読む `static let` も `nonisolated` にする）（2026-11-10、`ConnectionSettingsModel.normalizedLabel`）
- protocol の要件に extension で既定の実装を付けたとき、型の側の実装の署名が要件と違う（要件は `async throws(E)`、actor の側は同期で投げない、など）と、
  `any P` 越しの呼び出しは型の側を使うのに、具体的な型のまま呼ぶと extension の既定のほうが選ばれる（`InMemoryStateStore.snapshot()` が、型のまま呼ぶと自分を返していた）。
  既定の実装がある要件は、型の側も要件と同じ署名で書く（2026-11-10、#989）
- MainActor が既定のターゲットで `UIColor { traits in … }`・`NSColor(name:dynamicProvider:)` の処理を書くと、処理が MainActor に縛られる。
  SwiftUI は色を裏のスレッド（`com.apple.SwiftUI.AsyncRenderer`）で決めることがあり、そのとき実行時の確かめ（`_swift_task_checkIsolatedSwift`）で `EXC_BREAKPOINT` で落ちる。処理を `@Sendable` にして縛らない
- ジョブの `attempts` は、試行の前に人に渡したジョブ（直しの上限を超えた `fixTask`・`fixFinalPullRequest`）では 0 のまま `waitingHuman` になる。試行の番号を読む・使うところでは 0 を考える。
  `StatePath.attempt` は 1 以上の precondition で止まり（`askhub status` が止まった。#1039）、質問の版の読み方（`AnswerIntent.version`。1 以上）を流用した `JobTarget` は、やり直しの `targetVersion` の `"0"` を断っていた（2026-11-12、#1043）

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
- 同じ内容のコミットを作り直してブランチに push し直すと、コミットの時刻が違うので fast-forward にならず断られる。やり直しで同じブランチに push するスクリプトは、
  `git fetch origin refs/heads/<branch>` の後に `FETCH_HEAD^{tree}` と `HEAD^{tree}` を比べ、同じなら push を飛ばす（force しない）
- 偽の `gh` とローカルの bare リポジトリでスクリプトを確かめるときは、clone した checkout の origin を `https://github.com/<owner>/<repo>.git` にしたうえで
  `url.<bare のパス>.insteadOf` で書き換え、`GIT_ALLOW_PROTOCOL=file` を付けて流す。書き換えが漏れても https に出られないので、本物の GitHub に push しない
- macOS の `zipinfo` は、ロケールが C（launchd から起動したときの既定）だと UTF-8 の名前を `??` と出す（`LC_ALL=en_US.UTF-8` なら出る）。`unzip` は名前の引数をワイルドカードとして扱い
  （`a[1].txt` を渡すと「filename not matched」）、名前の位置の `-d` などもオプションとして読む。`[` `]` `*` `?` と先頭の `-` の前に `\` を付けると一致する。macOS の `zip` は UTF-8 の名前でも汎用フラグの bit 11 を立てない
- `claude -p --output-format json --json-schema '<schema>'` の結果では、決めた形の値が `structured_output` に入り（`result` は同じ内容の文字列）、実際に使われたモデルは `modelUsage` のキーで分かる。
  `--resume <session_id>` で再開した呼び出しの `total_cost_usd` と `modelUsage` の数は、その会話全体の累計（再開するたびに足すと二重に数える）。最後の結果の値を使う（2026-11-04、claude 2.1.317 で確かめた）
- 会社の Claude（Team・Enterprise。社用 MacBook）では、組織の管理の設定で MCP サーバーが止められていることがある。`claude -p --strict-mcp-config --mcp-config …` でも、stderr に「MCP server blocked by enterprise policy」と出て、道具が読み込まれない。手元に管理の設定のファイルは無く（サーバーから配られる）、`--restricted` でも外せない。ワーカーに Claude からビルドやテストを頼ませる仕組みは、MCP の道具ではなく、決まった形の報告で終わって `--resume` で結果を渡す往復にする（2026-11-07、段階 3 の設計）
- `claude -p --restricted --tools "Read,Edit,Write,Glob,Grep" --permission-mode dontAsk --settings '{"permissions":{"allow":["Read","Edit","Write","Glob","Grep"]}}'` で、Claude は作業ディレクトリのファイルを書き換えられる（作業ディレクトリの外は `--restricted` で書けない）。`--json-schema` の報告で終わらせ、`--resume <session_id>` に同じフラグを付けて続きを頼むと、同じ会話（同じ `session_id`）で続く（2026-11-07、claude 2.1.319）
- macOS には `timeout` コマンドが無い（GNU coreutils の）。シェルで時間の上限を付けるときは、Bash の道具の timeout か、プロセスを裏で起こして待つ形にする（2026-11-07）
- `ClaudeCommandLine` は環境変数を作り直し、`USER` を渡さない。setup-token（`CLAUDE_CODE_OAUTH_TOKEN`）の代わりに手元のログイン（Keychain の `Claude Code-credentials`。アカウント名はログインのユーザー名）で試すと、claude がログインを見つけられず「Not logged in · Please run /login」で `authExpired` になる。
  手元の claude で `TaskRunner` などを試すときは、`ClaudeSetup.executable` に、`CLAUDE_CODE_OAUTH_TOKEN`・`CLAUDE_CONFIG_DIR` を消して `USER` を足してから本物の claude を `exec` するラッパーを置く（2026-11-07、claude 2.1.319）
- macOS の `/bin/bash`（3.2）は、変数の直後に全角の文字が続くと、その文字まで変数名と読む（`"$PLIST）"` が `set -u` で `PLIST?: unbound variable`）。全角の文字が続く変数は `${PLIST}` のように波かっこで区切る。shellcheck では見つからない（2026-11-08、`scripts/commander/install-deployer.sh`）
- `--settings` に `"sandbox":{"enabled":true,"allowUnsandboxedCommands":false}` を足しても、`--restricted --tools "Read,Edit,Write,Glob,Grep" --permission-mode dontAsk` での書き換えと `--resume` はそのまま動き、stderr に警告も出なかった（Bash を渡さないので、sandbox が効く道具は無い。2026-11-07、claude 2.1.319・Haiku 5.5）

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
- macOS の `onDrop(of:delegate:)` の `DropDelegate.dropUpdated` で `.forbidden` を返すと `performDrop` が呼ばれない。落とした後に「添付できません」と知らせたいもの（ファイル以外）も `.copy` にして、`performDrop` の中で断る（2026-11-01、Discussion #784）
- `NSItemProvider.loadDataRepresentation(forTypeIdentifier:)` の完了ハンドラはメインスレッドの外で呼ばれる。このターゲットは MainActor が既定なので、クロージャに `@Sendable` を付けて
  MainActor に結び付けない（付けないと isolation の確認で落ちることがある）。`withCheckedContinuation` で包んで `async` にする（2026-11-01、Discussion #784）
- ドロップの受け口の modifier に「受け付けるか」を `Bool` で渡すと、項目を非同期に読み終えたときには描いたときの古い値になっている（読む間に送信が始まっても足してしまう）。
  `() -> Bool` のクロージャで受け取り、読み終えた時点で呼び直す（`attachmentDropTarget`。#791）（2026-11-01、Discussion #784）
- `NSItemProvider(object: url as NSURL)` は、ファイルの URL なら `public.file-url` を持ち、`https` の URL は持たない（`public.url` だけ）。ドロップのファイルかどうかの判定を Unit テストで確かめるのに使える。
  `FileManager.enumerator` の `.skipsPackageDescendants` はパッケージ（`.app`）の中に入らないが、パッケージのディレクトリそのものは返す（`isPackage` が true）ので、自分で除く（2026-11-01、Discussion #784）
- `NSItemProvider(object: url as NSURL)` の `loadDataRepresentation(forTypeIdentifier: "public.file-url")` は、macOS では URL の文字列のバイトを返すが、iOS では `["file://…", ""]` の binary plist を返す。
  そのため `URL(dataRepresentation:relativeTo:)` は iOS ではファイルの URL にならない（`isFileURL` が false）。macOS の受け口からだけ呼ぶ `AttachmentDropProviders.item(from:)` のこのテストは `#if os(macOS)` で流す（2026-11-01、#798）
- iOS 26 では、一覧の下に置くボタンの帯を `safeAreaInset(edge: .bottom)` にすると、ボタンと一覧の文字が重なって読みにくい。
  `safeAreaBar(edge: .bottom)` にすると、下にスクロールの端のぼかしが付いて読める（iOS 26 / macOS 26）（2026-11-03、リニューアルの UI）
- Mac の `List(selection:)` で選んだ行は濃い背景になり、`.red` や `.accentColor` の文字が読みにくい。
  `@Environment(\.backgroundProminence)` が `.increased` のときは色を付けない（2026-11-03、リニューアルの UI）
- リニューアルのクライアントは、DEBUG の起動引数で開く画面とデモの場面を決められる（`-demoScenario standard|quiet|failing|partial`・
  `-demoOpen deck:all`・`-demoOpen epic:<id>`・`-demoDrag 0:0.8`・`-demoReactionDelay 0`）。UI テストと PR のスクショはこれで撮る
  （`AskHub/Demo/DemoLaunch.swift`）（2026-11-03、リニューアルの UI）
- 英数字だけのフォント（Nunito）を `Font.custom(_:size:relativeTo:)` で使うと、かなと漢字は CoreText がシステムの書体（ヒラギノ角ゴ）で補い、太さも合わせる。
  可変フォントの名前付きインスタンスは PostScript 名（`Nunito-Bold` など）でそのまま選べる。`AskHub/` の下に置いたフォントは同期フォルダでバンドルの直下に入るので、
  Info.plist に並べずに `CTFontManagerRegisterFontsForURL` で登録できる。ナビゲーションバーの見出しとタブの名前は UIKit が描くので、`UINavigationBar.appearance()` で別に変える（2026-11-03、リニューアルの UI）
- `@ScaledMetric` と `UIFontMetrics.scaledFont(for:)` は、テキストサイズを標準（Large）より小さくしても縮まない（倍率は 1 のまま。大きくする方向だけに効く）。
  中身の寸法を縮めたいときは `dynamicTypeSize` の段階から本文の大きさの比を求める（`ContentScale`）。UIKit の見出しは `UIFont.preferredFont(forTextStyle:).pointSize` の大きさで作る（2026-11-03、リニューアルの UI）
- iOS 26 の `.lineHeight(.multiple(factor:))` を 1 より小さくすると、Nunito とヒラギノの文字の上が切れる。`.tight` は切れないが、2 行にわたる日本語が窮屈になる（2026-11-03、リニューアルの UI）
- iOS 26 の `.lineHeight(.multiple(factor:))` の倍率は、文字の大きさに対する倍率（行の高さ = 文字の大きさ × 倍率）。Nunito の標準の行の高さは約 1.36 倍（2026-11-03、リニューアルの UI）
- iOS 26 の標準の一覧（insetGrouped）の角の半径は約 24pt で、変える API が無い（`containerShape` も効かない）。`listRowBackground` で描いた地も、その角で切り取られる。
  角を変えるには `.listStyle(.grouped)` にして、行ごとに地を描く。セクションの中の行の位置は `Group(subviews:)` で数えられる（`CardSection`）（2026-11-03、リニューアルの UI）
- `NavigationLink` のラベルの中（行の見た目の部品）に付けた `listRowInsets`・`listRowBackground` は効かない。一覧の行そのもの（`NavigationLink` や ForEach の中身）に付ける（2026-11-03、リニューアルの UI）
- `ToolbarItemGroup(placement: .keyboard)` を最初から付けた画面で、開いてすぐ `onAppear` で入力欄にフォーカスを当てると、キーボードの上に「完了」が出ない（シートで確かめた。iOS 26.5）。
  `toolbar` の中身をフォーカスがあるときだけにして、フォーカスが付いてから足すと出る（`keyboardDoneButton(_:onlyWhileFocused:)`）。
  重ねたカードのように、付ける View が同じ画面に並ぶときも、フォーカスのある View の分だけ出るので重複しない（2026-11-03、リニューアルの UI）
- iOS でハードウェアキーボード（Simulator への文字の送り込みを含む）から打ったキーは、フォーカスのある `TextField` から親の View の `.onKeyPress` にも届く。
  親で数字キーを選択肢の番号として扱うときは、選択肢が 0 個（入力欄だけのカード）でも落ちない形で範囲を確かめる（`(1...count).contains(n)` は `1...0` で落ちる。`indices.contains(n - 1)` にする）。
  UI テストで確かめるときは `typeKey(_:modifierFlags:)` で打つ（`typeText` はソフトウェアキーボードの経路で入るので親の `onKeyPress` に届かず、落ちる不具合も再現しない）（2026-11-03、リニューアルの UI）
- `.sheet(item:)` を下へ払って閉じると、シートの中の「キャンセル」のボタンの処理を通らない。シートを出すために動かした View を戻すなどの後始末は、
  `.sheet(item:onDismiss:)` の `onDismiss` に置く（閉じ終わってから呼ばれるので、送ったときに後ろの View を動かす合図にも使える。`SwipeHold`）（2026-11-04、リニューアルの UI）
- SwiftUI の `DragGesture` は、引いている途中に 2 本目の指が触れると取り消され、`onEnded` が来ない（動かしていた View が途中で止まったまま残る）。
  2 本目を置いたまま 1 本目を離すと、2 本目の触れた位置を起点にした移動量で `onEnded` が来る。1 本目だけを追うには `UIGestureRecognizerRepresentable` で
  `UIPanGestureRecognizer` の派生を付け、最初の `UITouch` だけを `super` に渡してほかは `ignore(_:for:)` する（`SingleTouchPanRecognizer`）。
  Mac の `DragGesture` は `@GestureState` が戻るのを見て取り消しに気づく（2026-11-04、スワイプの手触り）
- `UIPanGestureRecognizer` は `maximumNumberOfTouches = 1` でも、2 本目を置いたまま 1 本目を離すと 2 本目へ乗り換える。`translation(in:)` はパンが始まった所（約 10pt 動いた所）から測り、
  `velocity(in:)` は指を止めてから離しても止める前の速さのまま残る。`UIGestureRecognizer` を直に派生すると、SwiftUI の Button の上から始めたとき Button の認識器
  （`UIKitResponderGestureRecognizer`）に止められて動かない（`UIPanGestureRecognizer` の派生なら止められない）（2026-11-04、スワイプの手触り）
- `UIGestureRecognizerRepresentable` の `converter` の `.local` は、ジェスチャーを付けた View の描画の変形（`offset`・`rotationEffect`）を含む座標になる。
  動かしている View の移動量を `.local` で測ると動きと打ち消し合うので、移動量は画面の座標（`location(in: nil)`）で測る（2026-11-04、スワイプの手触り）
- `DragGesture.Value.predictedEndTranslation` は「移動量 + 速さ × 0.25 秒」。`Spring.value(target:initialVelocity:time:)`・`velocity(...)` は `AnimatablePair` で 2 次元の初速（pt/秒のまま）を渡せる。
  SwiftUI のアニメーションの初速は 1 つの数だけなので、斜めの速さを引き継ぐときは時刻ごとに計算して `TimelineView` で描く（2026-11-04、スワイプの手触り）
- `rotation3DEffect` は、軸 (1, 0) を正の角度で回すと上の縁が、軸 (0, 1) では右の縁が奥へ下がる（2026-11-04、スワイプの手触り）
- シートの中の入力欄でキーボードを出すと、シートの後ろの画面（`NavigationStack` の行き先の View）も、キーボードの分だけ縦に縮む（iOS 26.5。まとめて判断するの札を置く領域が 646pt → 344pt）。
  後ろの View やその中の `GeometryReader` に `ignoresSafeArea(.keyboard)` を付けても戻らない（外側の層で縮むため）。シートの上に後ろの View を見せるときは、
  開く前の大きさを覚えておき、幅が同じまま高さだけ縮んだ間はその大きさで置く（`DecisionDeckView.deckArea`）（2026-11-06、自由回答のシート）
- `.presentationDetents([.height(h), .large])` のシートで開いてすぐ入力欄にフォーカスを当てると、キーボードが出たときに `.large` へ移る（`[.medium, .large]` と同じ）。
  低い高さのまま書かせるには `.large` を並べない。キーボードの上の「完了」（`ToolbarItemGroup(placement: .keyboard)`）は、低いシートではシートの中に重なって入力欄を狭める（2026-11-06、自由回答のシート）
- `List` の `Section` の中に、本体が `if` で何も出さないことのある View（`ReflectionStatusView` など）をそのまま置いても、何も出さないときは空の行にならない（iOS 26 で確かめた）。
  呼び出し側で `if` を重ねるのは、`CardSection` で包むときのように、包む側だけが残ってしまうときだけでよい（2026-11-09、反映中の UI）
- Mac・iPad の 3 列（`NavigationSplitView`）では、詳細の列に出す画面の `navigationTitle` がどこにも出ない（ツールバーに出るのは真ん中の列の名前だけ）。
  iPhone では大きな見出しになるので気づきにくい。詳細の列に出す一覧は、リポジトリの詳細のように札の中か、セクションの見出しにも画面の名前を入れる（2026-11-11、#1032 の `FinishedEpicListView`）
- アプリの自動の取り直しのように、次に読む時刻を `ClientStore` の時計（`now`）で数えると、デモの時計を止めて撮る（`-demoClock`）ときに時計が進まず、2 回目の取り直しが来ない。
  間隔は `ContinuousClock` の経過時間で数え、時計は GitHub の上限の戻る時刻のような「時刻」の比べにだけ使う（2026-11-12、`ClientStore.delayBeforeAutoRefresh`）
- `xcrun simctl launch` の直後に `xcrun simctl io <udid> screenshot` を撮ると、起動の途中の白い画面が写ることがある。数秒待ってから撮り、写ったものを目で確かめる（2026-11-12）
- Mac のシートは中身の理想の大きさで開くので、高さを持たない `List`・`Form` を入れると、見出しと閉じるボタンだけの高さに潰れて中身が空になる（macOS 26・27）。
  `presentationSizing(.form)`・`.page` で決まった大きさで開く（iOS 18 / macOS 15 からの共通の API。iPhone のシートには効かないので `#if os` は要らない。`SheetSize`）。
  Mac の `Form` の既定（columns）は、`TextField` の名前を欄の左の列に並べて欄を狭め、長い名前は左端で切れる。`.formStyle(.grouped)` にし、名前は `prompt:` と `.labelsHidden()` で欄の中に出す（iOS の見た目は変わらない）（2026-11-12、Mac の UI の直し）
- Xcode 26 の SDK でビルドした Mac のアプリを macOS 27 で動かすと、窓のツールバーの下が不透明の帯になり、背景を付けていない列（NavigationSplitView の詳細）だけツールバーの下が白く抜ける
  （26 はツールバーが透けて、下の列の背景が上まで見える）。`scrollEdgeEffectStyle(.soft, for: .top)` では消えず、`toolbarBackgroundVisibility(.hidden, for: .windowToolbar)` で 26 と同じになった。
  `.windowToolbar` は iOS に無いので Mac の分岐の中に書く（2026-11-12、Mac の UI の直し）
- Mac の NavigationSplitView は窓の最小の大きさを列の最小の幅から決めないので、窓を小さくすると詳細の列だけ 200pt ほどに潰れる。
  詳細の列にも `navigationSplitViewColumnWidth(min:ideal:)` を付け、窓の中身に `.frame(minWidth:minHeight:)`（3 列の最小の幅の合計）を付ける（2026-11-12、Mac の UI の直し）
