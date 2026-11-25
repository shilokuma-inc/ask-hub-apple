# GitHub App への切り替え（案 B）

司令塔・ワーカー・クライアントが使う GitHub のトークンを、持ち主（organization）ごとの fine-grained token から GitHub App に替える案の設計（#1307）。
2026-11-25 に、当面は案 A（持ち主ごとに毎日のトークン 1 つを全 Mac で共用＋管理用 1 つ）に作り直すと決めた。この文書は、その先でトークンを作る作業そのものを無くす案 B を検討する。

状態: 検討中（2026-11-25）。ユーザーの判断を待つ（下の「決めること」）。決まるまでは [security.md](security.md) の「トークン」・[operations.md](operations.md) の「GitHub のトークン（持ち主ごと）」「管理用のトークン（持ち主ごと）」が正本。
公式の文書で分かったことと、本物の App で確かめることを分けて書く。確かめの結果は「確かめが要る API」の表に書き足す。

## ねらい

- 司令塔の Mac でコマンドを 1 つ流し、ブラウザで GitHub の画面を押していけば、トークンを作る・貼る作業なしで終わる
- 毎年の作り直しを無くす（App の秘密鍵には期限が無い）
- 新しいリポジトリを作るたびに、トークンの Repository access に足す手作業を無くす
- 司令塔とワーカーを、人のアカウントの REST の上限（1 時間 5,000 回をすべての PC・アプリ・セッションで分け合う）から外す

## 今の手数（案 A）と比べる

| | 案 A（fine-grained token） | 案 B（GitHub App） |
| --- | --- | --- |
| 作るもの | 持ち主ごとに毎日のトークン 1 つと管理用 1 つ（5 つの持ち主で 10 個）。どれも GitHub の画面で、権限とリポジトリを 1 つずつ選ぶ | App を 2 つ（毎日・管理）。manifest flow で、ブラウザの「Create GitHub App」を 1 回ずつ押す |
| 各 Mac に入れる | 司令塔に 10 個、ワーカーの Mac ごとに 5 個を端末に貼る | 司令塔は App を作ったときに鍵が Keychain に入る。ワーカーの Mac は、毎日の App の鍵を 1 つ（App の画面で 1 回押してコマンドを 1 つ流す） |
| organization ごと | トークンを作る（organization によっては承認が要る） | App を Install する（毎日・管理の 2 回。1 回だけ） |
| 新しいリポジトリ | 毎日のトークン（司令塔と各 Mac）の Repository access に足す | All repositories で Install すれば何もしない（下の「Install の範囲」） |
| 毎年 | 10 個を作り直して、すべての Mac に貼り直す | 何もしない（鍵は取り消すまで使える） |
| 期限切れで止まる | ある（14 日前からクライアントで知らせている） | 無い。鍵を取り消した・Install を外したときだけ止まる |

## 形

### 毎日と管理で App を分ける

毎日の App（例 `askhub`）と管理の App（例 `askhub-admin`）に分ける。1 つにはしない。

- installation token は、作るときに権限とリポジトリを App の範囲の中で絞れる（`permissions`・`repositories`）。ただし絞るのは作る側のコードで、鍵を持つ者は App の持つすべての権限のトークンを作れる
- 1 つの App にすると、ワーカーの Mac の鍵で Administration・Workflows・Secrets のトークンを作れてしまう。今の決まり（毎日のトークンに Administration・Secrets・Workflows を持たせない。管理用は司令塔だけ）は、鍵の置き場所で守るしかない
- 2 つに分ければ、毎日の App の鍵は司令塔と各ワーカーの Mac に、管理の App の鍵は常時オンの Mac の司令塔にだけ置く。今の `GitHubTokens` と `GitHubAdminTokens` の分け方（Keychain の名前も部品も分ける。git の credential helper は毎日の部品しか受け取らない）をそのまま保てる
- クライアント（AskHub のアプリ）と非常口（`askhub`）は、3 つめの App（例 `askhub-client`）の user access token にする（下の「クライアント」）。App の秘密鍵はクライアントに入れない（GitHub の文書も、利用者の端末で動くアプリに秘密鍵を入れるなと書いている）

### 権限

| 権限 | 毎日の App | 管理の App | クライアントの App |
| --- | --- | --- | --- |
| Contents | Read and write | Read and write（ワークフローの直しのコミット） | Read and write（状態リポジトリ） |
| Pull requests | Read and write | Read and write（準備の PR を出す・マージする） | ― |
| Issues | Read and write | ― | ― |
| Discussions | Read and write | Read-only（カテゴリ「Ideas」を確かめる） | ― |
| Actions | Read and write（揺らいだ CI の流し直し・ログ・artifacts・`workflow_dispatch`） | ― | ― |
| Commit statuses | Read-only | ― | ― |
| Checks | Read-only（新しく足せる。fine-grained token では選べなかった。private のリポジトリの check runs も読める） | ― | ― |
| Administration | ― | Read and write（ルールセット・クラシックの保護・Discussions を有効にする・テンプレートからの作成） | ― |
| Repository creation | ― | Administration があれば要らない見込み（GitHub の表で、テンプレートからの作成に Administration と並んで載っている。作るだけの App 向けの権限）。テンプレートからの作成で確かめ、要れば足す | ― |
| Workflows | ― | Read and write | ― |
| Secrets・Environments | ― | Read and write | ― |
| Metadata | Read-only（必ず付く） | Read-only | Read-only |

- 毎日の App にも Workflows・Administration・Secrets を付けない。ワークフローのファイルを含む push は、fine-grained token と同じく GitHub が断る（GitHub の表で、App の Git Data・Contents の書き込みも Workflows の権限を見る）
- webhook は使わない（司令塔は今どおり見回りで読む）。manifest の `hook_attributes` は省くか `active: false` にする（どちらが通るかは確かめる）

### public にする

private の GitHub App は、持ち主のアカウントにしか Install できない（GitHub の文書）。5 つの organization で使うには、毎日の App と管理の App を public にする。

- public にすると、誰でもその App を自分のアカウントに Install できる。ただし、トークンを作れるのは秘密鍵を持つ者（司令塔・ワーカー）だけで、Install した人には何も渡らない
- 司令塔とワーカーは、設定の持ち主の一覧（`githubOwners`）にある organization の installation でしかトークンを作らない。知らない Install があっても使わない（自己診断に数だけ出す）
- 知らないアカウントに Install されている間は、private に戻せない（GitHub の文書）
- public にしない代わりは、organization ごとに App を作ること（5 つの organization × 2 で 10 個。鍵も 10 本）。手数が案 A に近づくので選ばない
- クライアントの App は状態リポジトリ（shilokuma-inc）だけに Install するので、private でよい

### App の持ち主

App を登録するアカウントは、shilokuma-inc（organization）を推す。

- 状態リポジトリと同じ持ち主になり、人のアカウントに結び付かない（App の設定は organization の owner と、任せた app manager が変えられる）
- manifest flow の宛先が `https://github.com/organizations/shilokuma-inc/settings/apps/new` になる。個人の持ち物なら `https://github.com/settings/apps/new`
- 1 つのアカウントが登録できる App は 100 個まで、名前は 34 文字まで（GitHub の文書）

### Install の範囲

| App | 範囲 | わけ |
| --- | --- | --- |
| 毎日の App | All repositories（推す。決めること） | 新しいリポジトリを足す手作業が無くなる。代わりに、毎日の App はその organization の全リポジトリ（ask-hub-apple・app-kit・テンプレートも）に push できる。develop・main・`release/` はルールセットで守っているので、直接は push できない |
| 管理の App | All repositories | テンプレートから作るには、作る前のリポジトリを選べないため（今の管理用のトークンと同じ）。App が作ったリポジトリには、GitHub が自動でその App の権限を付ける |
| クライアントの App | Only select repositories（状態リポジトリだけ） | 今のクライアントのトークンと同じ範囲 |

- 毎日の App を Only select repositories にする場合は、テンプレートから作ったリポジトリを人が毎日の App の Install に足す（今と同じ手作業。足すのは installation の画面の 1 か所で、各 Mac には何もしない）。installation のリポジトリを足す API は user access token が要るので、司令塔からは足せない
- installation の REST の上限は、installation のリポジトリが 20 を超えると増えるので、All repositories のほうが上限も大きい（下の「REST の上限」）

## 入れ方

### App を作る（manifest flow）

常時オンの Mac のログインしている端末（ssh からは Keychain に書けない）で、`askhub-commander github-app create` を流す（名前は仮）。

1. 司令塔が `127.0.0.1` の空いているポートで受け口を開き、ブラウザで受け口のページを開く
2. ページは、App の manifest（名前・権限・`public: true`・`redirect_url`・`setup_url`）を入れたフォームを `https://github.com/organizations/shilokuma-inc/settings/apps/new?state=<乱数>` に送る
3. GitHub の画面で、人が名前と権限を見て「Create GitHub App」を押す（1 クリック）
4. GitHub が `redirect_url`（`http://127.0.0.1:<ポート>/created?code=…&state=…`）に戻す。司令塔は `state` を確かめ、`POST /app-manifests/{code}/conversions` で App の id・slug・client ID・秘密鍵（PEM）を受け取る（3 つの手順を 1 時間以内に終える。この要求にトークンは要らない）
5. 秘密鍵は Keychain（`github-app-key/<App の slug>`）にだけ置く。ファイルに書かない。応答の client secret と webhook secret は使わないので、どこにも置かない
6. App の id・slug・client ID（秘密でない）を設定に書く
7. 続けて管理の App も同じ形で作る（もう 1 回「Create GitHub App」を押す）

- 今の `askhub-commander apns`（.p8 を読んで Keychain に置き、ファイルを残さない）より手数が少ない。鍵がファイルとして Mac に出ないため
- `redirect_url`・`setup_url` に `http://127.0.0.1:<ポート>` を使えるかは、GitHub の文書に書いていない。確かめる（下の「確かめが要る API」）。使えなければ、受け口のページに code を貼ってもらう形にする

### organization に Install する

App を作ったら、司令塔が持ち主ごとに Install の画面（`https://github.com/apps/<slug>/installations/new`）を順に開く。

- 人は、organization を選び → All repositories を選び → Install を押す（organization ごと・App ごとに 1 回。5 つの organization で 10 回。1 回だけ）
- manifest の `setup_url` に受け口を入れておくと、Install の後に GitHub が `installation_id` を付けて戻すので、司令塔は済んだ organization を端末に出して次を開く。戻らなくても、司令塔は JWT で `GET /orgs/{org}/installation` を読んで確かめる
- Install できるのは、その organization の owner（今の 5 つの organization は、どれもユーザーが owner）
- 新しい持ち主を足すときは、その organization に 2 つの App を Install して、設定の `githubOwners`（管理の操作もするなら `adminOwners`）に足す。トークンを作る・貼る作業は無い

### ワーカーの Mac に鍵を入れる

ワーカーには毎日の App の鍵だけを入れる。管理の App の鍵は入れない。

1. ワーカーの Mac の端末で `askhub-worker github-app key` を流す（名前は仮）。ブラウザで毎日の App の設定の画面が開く
2. 人が「Generate a private key」を押す（1 クリック）。PEM がダウンロードのフォルダに落ちる
3. ワーカーがダウンロードのフォルダに出た PEM を見つけて Keychain に置き、ファイルを消す。鍵の指紋（SHA-256）を端末に出す（App の画面の指紋と照らし合わせられる）

- Mac ごとに別の鍵にする。Mac を失くしたら、App の画面でその Mac の鍵だけを消せる（1 つの App に 25 個まで作れる。期限は無い）
- 司令塔の鍵を ssh で写す形にはしない（ssh からは Keychain に書けないうえ、1 本の鍵が漏れたら全部の Mac の鍵を替えることになる）
- 常時オンの Mac のワーカーの役（`--build-capacity`）は、司令塔の毎日の App の鍵を使う

### 手数のまとめ

| 場面 | 人がすること |
| --- | --- |
| 初めて | 常時オンの Mac で 1 コマンド → 「Create GitHub App」を 2 回 → Install を 10 回（organization を選んで押す）。ワーカーの Mac ごとに 1 コマンドと 1 クリック |
| organization を足す | Install を 2 回と、設定の持ち主に足すコマンド |
| 新しいリポジトリ | 何もしない（毎日の App を All repositories にした場合） |
| 毎年 | 何もしない |
| Mac を失くした | App の画面でその Mac の鍵を消す |

## 動き

### installation token の部品

司令塔とワーカーに、App の鍵から installation token を作って使い回す部品（仮に `GitHubAppTokens`。actor）を足す。

1. JWT を作る: RS256（鍵は PKCS#1 の RSA。Security framework の `SecKeyCreateWithData` と `SecKeyCreateSignature` で署名できる）。`iss` は client ID、`iat` は 60 秒前、`exp` は 9 分後（上限は 10 分）
2. 持ち主の installation の id を読む: JWT で `GET /orgs/{org}/installation`。id は覚えておく（Install し直したら 404 になるので読み直す）。設定の持ち主の一覧に無い organization には作らない
3. installation token を作る: `POST /app/installations/{id}/access_tokens`。1 時間で切れるので、`expires_at` の 10 分前まで使い回し、それより後は作り直す。並んだ要求が同時に作り直さないよう、作っている間は待たせる
4. 権限を絞る: 毎日の App のトークンを作るときに、使う権限だけを `permissions` で渡す（App の権限より広くはできない）。ジョブのトークンを `repositories` でそのリポジトリと状態リポジトリに絞るのは、後から足せる

- トークンの形は `ghs_` で始まり、2026-04-27 から長さが 40 文字と決まらない新しい形に順に替わっている（GitHub の文書）。今の `GitHubTokens.problem(of:)` の `github_pat_` の確かめは、App のトークンには当てない
- 値はこれまでどおり `Authorization` にだけ入れ、ログ・URL・エラー・状態リポジトリに出さない

### 今の部品の置き換え

GitHub を呼ぶ部品の多くは、トークンを「持ち主を受け取ってトークンを返す関数」（`@Sendable (owner) async throws -> String`）で受け取っている。その関数の中身を替えれば、呼ぶ側はほとんど変えずに済む。

| 今の部品 | 替え方 |
| --- | --- |
| `MachineRuntime.githubToken(for:in:)`・`githubTokens(in:)`（状態リポジトリ・PR・Discussion・リリースなど） | 毎日の App の installation token を返す。持ち主ごとに App とトークンを切り替えられるようにする（下の「移り方」） |
| `GitCredential`（`git-credential get`） | 別のプロセスとして呼ばれるので、作ったトークンを Keychain（`github-app-token/<持ち主>`。値と `expires_at`）に置いて、常駐と credential helper で分け合う。切れていれば credential helper が自分で作る（同じ署名のプログラムなので Keychain の確認は出ない）。ユーザー名は今と同じ `x-access-token` |
| `AdminTokens`・`AdminGitHub` | 管理の App の installation token を返す。断るわけに「管理の App が Install されていない」「鍵が無い」を足す。上限の待ち（`AdminPauses`）は installation ごとに分ける |
| `GitHubCommitAuthors`（`GET /user` で書き手を決める） | installation token では `GET /user` を使えない見込み（確かめる）。書き手を設定で決める（下の「コミットの書き手」） |
| `GitHubOwnerRepositories`（`orgs/{org}/repos`・`user/repos`） | `GET /installation/repositories` で、Install した範囲のリポジトリを読む |
| `GitHubTokenExpiry`・自己診断の `githubTokens`・`githubAdminTokens` | 期限の代わりに、鍵の様子（JWT が 401 なら取り消された）と Install の様子（無ければ未 Install）を書く。上限の残りは、installation token で `GET /rate_limit` を読む（今と同じく上限に数えない） |
| クライアントの「トークンの期限」と 14 日前の知らせ | 期限が無いので要らなくなる。鍵が取り消された・Install が外れたときだけ「止まっています」に出す |
| Discussion の写し（`viewerDidAuthor` で自分の写しを探す） | 書き手が bot に変わるので、移る前に人のアカウントで書いた写しを自分のものと見られない。移る前の写しも自分のものとして扱う手当てが要る（下の「Discussion の写し」） |
| PR の画像の添付（`user-attachments/assets`） | App のトークンでは GitHub が断る見込み。画像の置き場所を替える（下の「画像の添付」） |

### REST の上限

| | 今 | 案 B |
| --- | --- | --- |
| 司令塔とワーカー | 人のアカウントの 5,000/h を、クライアント・Claude のセッションの `gh` と分け合う | installation ごとに別の枠。最低 5,000/h で、installation のリポジトリが 20 を超えると 1 つにつき 50/h 増える（上限 12,500/h）。shilokuma-inc を All repositories で Install すると、48 本で 6,400/h 前後 |
| 毎日と管理 | 毎日のトークンと管理用のトークンも同じアカウントの枠 | 毎日の App と管理の App で枠が別（管理の操作が毎日の仕事の枠を食わない） |
| クライアント・`gh`・非常口 | 人のアカウントの 5,000/h | 人のアカウントの 5,000/h のまま（user access token は、そのユーザーの PAT や `gh` と同じ枠に数える。GitHub の文書） |

- 2026-11-11 の調べでは、司令塔が 1 時間に約 1,000 回（epic 1〜2 本）、ジョブのチェック待ちが 1 本につき 120 回を使っていた。これが人の枠から外れ、人の枠はクライアントと Claude のセッションだけになる
- 状態リポジトリ（shilokuma-inc）の読み書きは、司令塔と全部のワーカーが shilokuma-inc の毎日の App の installation の枠で分け合う。一番減りやすい枠になるので、自己診断の上限の残りは持ち主（installation）ごとに今どおり書く
- 司令塔は人のトークンを持たなくなるので、人のアカウントの残りを測れない。クライアントが自分の user access token で `GET /rate_limit`（上限に数えない）を読んで出す
- 二次の上限（同時 100・内容を作る要求 1 分 80 回など）は、installation で別の値になるとは書かれていない。今の書き込みの予算（`WriteBudget`）はそのまま残す

## 確かめが要る API

GitHub の文書（「Permissions required for GitHub Apps」など）で分かったことと、本物の App で確かめることを分ける。確かめは、試しの App（下の「確かめの道具」）を shilokuma-inc/askhub-sandbox に Install して行う。

| 確かめること | 文書で分かったこと | 本物で確かめること | 結果 |
| --- | --- | --- | --- |
| manifest flow の受け口 | `redirect_url` に code と state が返る。3 つの手順を 1 時間以内に終える。conversion の応答に `pem`・`client_id`・`client_secret`・`webhook_secret` が入る | `http://127.0.0.1:<ポート>` を `redirect_url`・`setup_url` に使えるか。`hook_attributes` を省けるか | 未 |
| テンプレートからの作成（`POST /repos/{owner}/{repo}/generate`） | installation token で使える。Repository の Administration か Repository creation の write と、テンプレートの Contents の read。作ったリポジトリには App の権限が自動で付く | 別の organization の public のテンプレート（shilokuma-inc/template-app-ios → tm-family など）から作れるか。Only select repositories の Install でも作れるか | 未 |
| Secrets の登録 | 公開鍵の読み取りは Secrets の read、登録は write。Environment の Secrets は Environments | 公開鍵を読み、`SealedBox` で暗号化して入れ、消せるか | 未 |
| ルールセット | 作る・変える・消すは Administration の write、読むのは Metadata の read。`bypass_actors` に App（`Integration`）も入れられる | 効かない形（`enforcement: disabled`）のルールセットを作って消せるか | 未 |
| Discussions を有効にする（`PATCH /repos/{owner}/{repo}` の `has_discussions`） | Administration の write。ただし `has_discussions` は Update の文書の引数に載っていない（今の fine-grained token では通っている） | App のトークンで通るか | 未 |
| Discussions の GraphQL | App から使える（権限の名前は文書に無い。足りなければ 401） | カテゴリを読む・Discussion とコメントを書く・自分のコメントを直す。`viewer` が bot になり、bot の書いたものの `viewerDidAuthor` が true か。人が書いたコメントの `viewerCanUpdate`（移る前の写しを直せるか） | 未 |
| Actions の再実行 | `rerun-failed-jobs`・`workflow_dispatch`・取り消しは Actions の write、ログ・artifacts は read | 落ちた run を流し直せるか（試しの App では、落ちた run があるときだけ） | 未 |
| 状態リポジトリへの書き込み | Contents の write。git の https は `x-access-token` とトークン | Contents API で書けるか、git の push が通るか（askhub-sandbox の確かめ用のブランチで行い、状態リポジトリには書かない） | 未 |
| ワークフローのファイルの変更 | Contents と Workflows の write | Workflows の権限があればワークフローのファイルを含むコミットを書けるか（試しの App は管理の App と同じく Workflows を持たせる） | 未 |
| App のトークンで GitHub Actions が動くか | `GITHUB_TOKEN` で起こしたイベントは（`workflow_dispatch` などを除き）ワークフローを起動しないが、App の installation token や PAT なら起動する（文書が代わりに使えと書いている） | App のトークンで出した PR・push で、askhub-sandbox のワークフローが動くか | 未 |
| `GET /user` | installation token で使えないとは、読んだ文書に書いていない | 403 になるか | 未 |
| bot のアカウント | ― | `GET /users/<slug>[bot]` で bot の id を読めるか。Contents API で作ったコミットが Verified になるか | 未 |
| check runs | Checks の read で読める | 読めるか | 未 |
| 上限 | installation ごとに 5,000/h から | `GET /rate_limit` の `limit`。期限の見出し（`github-authentication-token-expiration`）が付くか | 未 |
| 画像の添付（`user-attachments/assets`） | 公式の API ではない（gh の `--attach` と同じもの）。installation token も、自前の App の user access token も GitHub が断る（cli/cli#14309・#14495） | 404 で断られるか（上げられると消せない画像が残るので、引数を付けたときだけ） | 未 |
| 専用のブランチの画像 | ― | 孤立したブランチにコミットした画像を、PR の本文で sha で固定した URL から出せるか（public と private） | 未 |
| CodeRabbit | 席の無い bot の PR には要約と注記だけ（下の「CodeRabbit」） | askhub-sandbox（public）で bot が出した PR に、レビューが付くか、要約だけか。check run `CodeRabbit` の結果 | 未 |
| クライアントの device flow | App の設定で Enable Device Flow を有効にする。client secret は要らない | 状態リポジトリだけを触れる user access token が取れるか。`GET /rate_limit` が人の枠を返すか | 未 |

### 確かめの道具

試しの App を作って上の表を順に試すコマンドを、リポジトリの外に用意する（実装の PR には入れない）。人がすることは次の 3 つ。

1. 手元の Mac の端末で `askhub-app-probe create --org shilokuma-inc` を流し、ブラウザで「Create GitHub App」を押す。続けて開く Install の画面で、Only select repositories で shilokuma-inc/askhub-sandbox だけを選んで Install を押す
   - 試しの App は private にし、名前は `askhub-probe-<16 進の 4 文字>`。権限は毎日と管理を合わせたもの。鍵は試しの道具の Keychain（`jp.shilokuma.AskHub.app-probe`）にだけ置く
2. `askhub-app-probe check --repo shilokuma-inc/askhub-sandbox` を流す。表の確かめを順に行い、結果（状態コード・`X-Accepted-GitHub-Permissions`・書き手）を出す。askhub-sandbox に作るもの（確かめ用のブランチ・PR・Discussion・空のルールセット・Secret）は、終わったら消すか閉じる
   - 消せないものを作る確かめは、引数を付けたときだけ行う: `--attach`（1 画素の画像を上げる。public のリポジトリでは誰でも見られ、消せない）、`--template <テンプレート> --new-repo <名前>`（リポジトリを作る。消すのは人が GitHub の画面で行う）、`--rerun`（落ちた run を流し直す。CI の時間を使う）
3. 終わったら、App の設定の画面（Advanced → Delete GitHub App）で試しの App を消し、`askhub-app-probe forget` で Keychain の鍵を消す

- 別の organization のテンプレートからの作成は、試しの App を public にして tm-family にも Install したときだけ確かめられる（private の App は持ち主にしか Install できないため）
- device flow は、試しの App の設定で Enable Device Flow を有効にしてから `askhub-app-probe device-login` で確かめる

## 変わること

### 書き手が bot になる

PR・コメント・Discussion の写し・API で作るコミットの書き手が、`askhub[bot]`（管理の操作は `askhub-admin[bot]`）になる。

- [security.md](security.md) の「人と機械の見分け方」の前提（人・司令塔・ワーカーが同じアカウントで書く）が変わる。書き手で機械と人を見分けられるようになる（`[bot]` の付いた名前は、ほかの人が名乗れない）
- それでも、指示として扱うのは状態リポジトリの署名した人の意図だけのまま。目印の決まりも残す（public のリポジトリには誰でも書けるうえ、移る前の写しは人のアカウントで書いてある）
- 人は bot の PR を GitHub で承認できるようになる（作者でないため）。ルールセットの承認の数は今の 0 のままにする（AskHub の承認は署名した人の意図で行う）。上げる余地ができることだけを書いておく

### コミットの書き手

今は、トークンの持ち主（人のアカウント）をコミットの書き手にしている（`GitHubCommitAuthors`。PR を開く・マージするアカウントとそろえる、という決定）。App では次のどちらかを選ぶ（決めること）。

| | 書き手（author） | 良いところ | 気になるところ |
| --- | --- | --- | --- |
| 人のまま（推す） | 人のアカウントの noreply アドレス（設定で login を決め、`GET /users/<login>` で id を読む）。committer を bot にする | 既定のブランチに入ったコミットが、今どおり人の草（contributions）に数えられる。GitHub の画面に「人が書き、`askhub[bot]` がコミットした」と出る | PR の作者（bot）とコミットの書き手（人）が分かれる。API で作るコミットも署名なし（今と同じ） |
| bot | `<bot の id>+askhub[bot]@users.noreply.github.com`（bot の id は `GET /users/askhub[bot]`。App の id とは別の値） | PR の作者とそろう。機械の書いたものだと一目で分かる。API で作るコミットが Verified になる | 人の草に数えられなくなる |

- GitHub は、App として認証した要求で、author・committer を指定せずに作ったコミットを、自分の鍵で署名して Verified にする（GitHub の文書。GraphQL の `createCommitOnBranch` は必ずこの形）。Git Data API でも同じになったという報告があるが、Contents API は報告が食い違う。git で push するコミットは、どちらの書き手でも署名なし（今と同じ）
- ルールセットで署名を必須にしていないので、Verified でなくてもマージは止まらない

### CodeRabbit

CodeRabbit の文書（2026-11-25 に読んだ）では、次のとおり。

- bot の PR を既定で飛ばす決まりは無い（飛ばすのは `.coderabbit.yaml` の `reviews.auto_review.ignore_usernames` に書いた作者だけ）
- ただし、GitHub が bot と見なすアカウント（GitHub App を含む）には、有料の席（seat）を自動では割り当てない。席の無い作者の PR には、無料の要約と「作者に席が無い」の注記だけが付き、`@coderabbitai full review` でも越えられない。管理者が CodeRabbit の画面で、bot に手で席を割り当てられる
- public のリポジトリ（OSS）は有料の契約なしで使える。public のリポジトリの bot の PR に席が要るかは、文書に書いていない
- レート制限は PR を開いたアカウントごとに数える（push 1 回で 1 回分）。今は AskHub の PR も人が手で出す PR も人のアカウントの枠を分け合っているが、App では AskHub の PR が `askhub[bot]` の枠にまとまり、人の PR の枠と分かれる

そのため、次を確かめてから決める。

- askhub-sandbox（public・shilokuma-inc）で bot が出した PR に、CodeRabbit のレビューが付くか、要約と注記だけか。そのときの check run `CodeRabbit` の結果（ワーカーの最終 PR のレビュー待ちが、見送り（`skipped`）を「レビューが付かない」として進めるか）
- 要約だけなら、CodeRabbit の画面で `askhub[bot]` に席を割り当てる（人の作業。shilokuma-inc の CodeRabbit の契約で、bot に席を割り当てられるか・費用が増えるかを確かめる）か、bot の PR では CodeRabbit を待たない（ビルドの設定の `trustedReviewers` から外す）かを選ぶ（決めること）

### No AI Attribution のチェック

コミットのメッセージと PR の本文に AI の帰属の行があるかだけを見る（`.github/workflows/no-ai-attribution.yml`）。書き手は見ないので、bot に変わっても変わらない。App のトークンで出した PR でワークフローが動くことは、上の表で確かめる。

### ルールセット

- 今の `askhub-protect`（PR 必須・承認 0・必須のチェック・force push と削除の禁止・例外なし）は、そのまま効く。App も例外にしない
- 必須のチェックは GitHub Actions（`integration_id` 15368）が出したものだけを数えるので、App に替えても変わらない
- 保護の設定・ずれの点検は、管理の App（掛ける）と毎日の App（Metadata の読み取りで点検する）に分かれる。今の分け方と同じ

### Discussion の写し

司令塔は、自分が書いた写しを `viewerDidAuthor` で見分けている。App に替えると `viewer` が bot になるので、移る前に人のアカウントで書いた写し（目印つきの本文とコメント）を自分のものと見なくなり、同じ目印の写しを作り直すおそれがある。

- 持ち主を App に切り替える前に、目印の付いた写しの書き手が「bot か、設定の前の書き手（人の login）」なら自分のものとして扱う手当てを入れる（GraphQL で `author { login }` も読む）
- 前の写しを直す（コメントの書き換え）には、App がほかの人のコメントを直せる必要がある。`viewerCanUpdate` で確かめ、直せなければ、前の写しは直さずに新しい写しを足す

### 画像の添付

判断のカードの Before / After の画像は、`user-attachments/assets`（gh の `--attach` と同じ、公式に載っていない API）で上げている。

今は fine-grained token で上げている（#1003 の epic で、Before・After とも添付に成功した）。App では上げられない見込みが強い。

- `user-attachments/assets` は公式の API ではなく、GitHub の側で受け付けるトークンを絞っている。Actions の `GITHUB_TOKEN`（installation token）では 404 になり、gh のメンテナーは「今は意図した動き」と答えている（cli/cli#14309）
- 自前の GitHub App の user access token（`ghu_`）も通らない。今は GitHub 自身の一部の App（Copilot など）のトークンだけが通り、利用者の App で通す設定は無い（cli/cli#14495。2026-10-14 のメンテナーの答え）

そのため、App に替えるなら、判断のカードの画像の置き場所を次のどれかにする（決めること）。

| 案 | 中身 | 良いところ | 気になるところ |
| --- | --- | --- | --- |
| 専用のブランチ（推す） | 対象のリポジトリの決まった名前のブランチ（例 `askhub-assets`。develop の履歴とつながらない孤立したブランチ）に、epic ごとの画像をコミットし、最終 PR の本文からコミットの sha で固定した URL で参照する | App のトークン（Contents の write）だけでできる。添付と違って消せる。public のリポジトリなら誰でも見られる | リポジトリの大きさが画像の分だけ増える。private のリポジトリの PR の本文で出せるかは確かめる。ブランチを消すと、前の PR の画像が切れる |
| AskHub の中だけ | 画像は今どおり状態リポジトリに置いてクライアントで見せ、最終 PR の本文には載せない（「AskHub で見る」と書く） | 作るものが一番少ない | GitHub の PR の画面では Before / After を見られない |
| 添付のためだけに人のトークンを残す | 司令塔に fine-grained token を持ち主ごとに残し、添付だけに使う | 今の見た目のまま | トークンを作る・作り直す作業が残り、案 B のねらいから外れる |

### クライアント

クライアント（iOS・macOS）と非常口は、トークンを貼る代わりに「GitHub でサインイン」（device flow）にする。

1. クライアントが `POST https://github.com/login/device/code`（クライアントの App の client ID）で、8 文字のコードを受け取る
2. 人が `https://github.com/login/device` を開いてコードを入れ、許可する（iPhone なら、コードを写したうえで Safari を開く）
3. クライアントが `POST https://github.com/login/oauth/access_token` を間隔を守って問い合わせ、user access token（`ghu_`）と refresh token（`ghr_`）を受け取り、Keychain にだけ置く

- client secret は要らない（device flow のトークンは、作るのも作り直すのも client secret なしでできる。GitHub の文書）。アプリに秘密を埋め込まない
- トークンで触れるのは、App の権限と人の権限が重なり、App を Install したリポジトリだけ。クライアントの App は状態リポジトリだけに Install するので、今のクライアントのトークンと同じ範囲になる
- 書き込みは人のものとして記録され、画面では人のアバターに App のバッジが付く
- 期限は既定で 8 時間（refresh token は 6 か月）。期限を切る設定（App の設定の Optional Features）もある。推すのは期限ありのまま（GitHub も推す）で、クライアントが切れる前に作り直す。refresh token は使うと替わるので、作り直しは 1 つずつ行う。6 か月開かなかった端末は、サインインし直す
- 上限は今と同じく人のアカウントの 5,000/h
- Enable Device Flow と期限の設定は、manifest では決められない。クライアントの App を作った後に、App の設定の画面で有効にする（2 か所を押す）
- GitHub の文書は、device flow を CLI や画面の無い端末向けとし、App になりすましたコードの入力を誘う手口に注意を促している。ネイティブのアプリの代わりは web flow と PKCE だが、トークンを作るのに client secret が要り、アプリに埋め込むことになる。device flow を推す

### 共同開発者

今の設計では、共同開発者のワーカーはその人のアカウントとトークンで動き、その人の上限を使う（[operations.md](operations.md) の「共同開発者の Mac」）。App に替えるときは次のどちらかになる。受け入れの仕組みを作るときに決める。

- 同じ毎日の App の鍵を、共同開発者の Mac にも作って入れる（書き手は `askhub[bot]`、上限は installation の枠を分け合う）
- 共同開発者が、同じコマンドで自分の App を作る（その人の bot になる。organization に Install するときに owner の承認が要る）

## 移り方

今の fine-grained token（案 A で作り直すもの）と並べて動かし、持ち主ごとに切り替える。

1. 確かめ: 確かめの道具で上の表を埋める。通らないものがあれば、この文書を直してから決め直す
2. 部品を作る: `GitHubAppTokens`・`github-app` のコマンド・自己診断の形。設定に持ち主ごとの切り替え（例 `githubAuth: { "tm-family": "app" }`。無ければ今の fine-grained token）を足す。切り替えは毎日と管理で別に持つ
   - PR の分け方の見込み: (1) JWT と installation token の部品・設定・自己診断と protocol.md の形 → (2) `github-app` のコマンド（作る・Install・ワーカーの鍵） → (3) git の credential helper・管理の部品・コミットの書き手・リポジトリの一覧を切り替えに乗せる → (4) Discussion の写しの前の書き手・判断のカードの画像の置き場所 → (5) クライアントと非常口のサインイン
3. App を作って Install する: 2 つの App を作り、5 つの organization に Install する。まだ切り替えない（自己診断に App の様子だけが出る）
4. 試しの持ち主で切り替える: tm-family（app-kit の試しの 1 本と同じ持ち主。リポジトリが少ない）を App に切り替え、epic を 1 本、依頼から最終 PR のマージと TestFlight まで通す
5. 残りを切り替える: shariverse・BeaconFun4・shilokuma-vision → 最後に shilokuma-inc（状態リポジトリの持ち主。司令塔とワーカーの全部が切り替わる）
6. クライアントを切り替える: クライアントの App を作り、サインインを足した版を出す。トークンを貼る形は、しばらく並べて残す
7. 片付け: すべての持ち主が 2 週間止まらずに動いたら、fine-grained token を GitHub の画面で取り消し、Keychain から消す。fine-grained token の部品と、期限の知らせを外す

### 戻し方

- 持ち主ごとの切り替えを fine-grained token に戻すだけで戻る（常駐を読み込み直さなくても、次の要求から使う形にする）。案 A のトークンは 1 年使えるので、片付けまでは消さない
- 戻しても、App の書いた PR・コメントは残る。戻す前の Discussion の写しは bot が書いているので、戻した後も「前の書き手」として bot を自分のものと見る（上の手当てを両向きにする）
- App そのものを止めるときは、organization の Install を外す（その organization のトークンがすぐ作れなくなる）。鍵が漏れたときは、App の画面で鍵を消す

## 決めること

推しと一緒に並べる。

1. **案 B に進むか**: 推しは「進む。ただし確かめの道具で本物を確かめてから決める」。当面は案 A のトークンで動かし、案 B の部品ができたら持ち主ごとに移る
2. **App の分け方**: 推しは 3 つ（毎日・管理・クライアント）。毎日と管理を分けないと、今の決まり（管理の権限は司令塔だけ）を鍵の置き場所で守れない
3. **public にするか**: 推しは毎日と管理の App を public にする（private では 5 つの organization に Install できない）。クライアントの App は private
4. **App の持ち主**: 推しは shilokuma-inc
5. **毎日の App の Install の範囲**: 推しは All repositories（新しいリポジトリを足す手作業が無くなる）。代わりに、毎日の App はその organization の全リポジトリに push できる
6. **コミットの書き手**: 推しは人のまま（committer を bot にし、草に数える）。PR の作者とそろえるなら bot
7. **ワーカーの鍵**: 推しは Mac ごとに別の鍵（Mac を失くしたら、その鍵だけを消せる）
8. **クライアントのサインイン**: 推しは device flow で、期限ありのまま（クライアントが作り直す）
9. **移る順**: 推しは tm-family → shariverse・BeaconFun4・shilokuma-vision → shilokuma-inc → クライアント。片付けは全部の持ち主で 2 週間動いてから
10. **判断のカードの画像**: App では `user-attachments` に上げられない見込み。推しは専用のブランチに置いて、最終 PR の本文から sha で固定した URL で参照する
11. **CodeRabbit**: bot の PR に要約しか付かなかったときに、`askhub[bot]` に席を割り当てるか、bot の PR では CodeRabbit を待たないか。推しは「askhub-sandbox で確かめてから決める。席を割り当てられて費用が増えなければ割り当てる」

## 残る気がかり

- 毎日の App の鍵が漏れると、Install した organization の全リポジトリ（All repositories の場合）に書けるトークンを作れる。今の fine-grained token（選んだリポジトリだけ・1 年で切れる）より範囲が広く、期限が無い。Mac ごとの鍵と、Claude とビルドにトークンも鍵も渡さない今の隔離（[security.md](security.md) の「Claude の隔離」）で受け止める
- public の App は、知らない人に Install されると private に戻せなくなる。使わない Install は害が無いので、そのまま放っておく
- GitHub は user access token の期限を「変わることがある」任意の機能としている
- installation token の形が変わっている途中（`ghs_` の新しい形。長さが決まらない）。長さで確かめない
