# 共通リポジトリ（app-kit）とテンプレート

[plan.md](plan.md) の段階 5 の 5「共通リポジトリ（app-kit）とテンプレートの作り直し・配布」の設計（#1210）。
元の方針は [operations.md](operations.md) の「共通リポジトリとテンプレートの配布」。この文書は、その方針を作れる形まで決める。

状態: 2026-11-22 にユーザーが決め、設計を承認した（下の「決めたこと」）。同じ日に `shilokuma-inc/app-kit` を作り、v1.0.0 を出した（下の「実装の順と PR の分け方」の 1〜5。app-kit の #2・#4・#6・#8・#10）。試しの 1 本の入れ替えは tm-family/shinkeisuijaku-app-ios#83。

## ねらい

- CI・リリースのワークフローと道具の直しを、1 か所で直せば全リポジトリに届くようにする（今は直しをリポジトリごとに手で写している）
- 届け方を AskHub の中に収める。新しい版が出たら、人はクライアントで変更点を見て 1 回押すだけにする
- どのリポジトリがどの版か、手で変えられてずれていないかを、クライアントで見られるようにする
- テンプレートから作ったリポジトリが、最初から同じワークフローを使うようにする

## 今のずれ

2026-11-22 に、状態リポジトリの `repos/` のうち外していない 8 本と、テンプレート 3 本を調べた（読むだけ。リポジトリごとの表は、この設計を書いたセッションの共有ノート `app-kit.md` に残した）。

| 見たもの | 分かったこと |
| --- | --- |
| ワークフローの形 | テンプレート由来の 6 本（OshiCon・demomoni・kobosu・kobuta-tap・shinkeisuijaku・ask-hub-apple）は、もう同じリポジトリの中の再利用ワークフロー（`_build.yml`・`_archive.yml`）を呼ぶ形。prime-pick-ios は古い 3 本立て（build-develop・build-main・build-working）、askhub-sandbox は 1 本だけの独自の `build.yml` |
| 中身のずれ | `build.yml`・`_build.yml` はテンプレート由来の 5 本でテンプレートと同じ。`_archive.yml` はどれも ±82〜261 行ずれている。スタブのフレームワークの署名の直し（10-22）・署名なしの Archive に entitlements を入れる直し（11-12）・TestFlight の内部テスターが、入っているリポジトリと入っていないリポジトリに分かれる |
| 直しの向き | 両方ある。`ensure-internal-testers.rb` は shinkeisuijaku が一番新しく、テンプレートより進んでいる。entitlements の直しと Dynamic Island を重ねる道具（11-22）は、テンプレートにしか無い |
| App Store の素材 | `app-store-metadata.yml`・`verify-app-store-metadata.yml`・`app-store-creative-assets.yml` と、Python の道具 10 本（`Tools/`）。リポジトリごとに ±4〜442 行ずれている。掲載文・App Review の情報・スクショの反映は、もう司令塔が API で行っている（[release.md](release.md)） |
| スクショの撮影 | `app-store-screenshots.yml` は 6 本が持ち、±70〜151 行ずれている。司令塔がこのワークフローを `workflow_dispatch` で起動して撮る（[store-screenshots.md](store-screenshots.md)） |
| 設定 | `.swiftlint.yml` はテンプレート由来ならどこも同じ（ask-hub-apple だけ除外が 1 行多い）。`.coderabbit.yaml` も近いが、prime-pick・quiz・visionOS のテンプレートは子 PR の除外が `epic/**` のまま。Issue・PR のテンプレートは prime-pick のほかは同じ |
| CLAUDE.md | 8 本のうち 5 本にしか無く、見出しもばらばら。`## 全員向けの事実` の節があるのは askhub-sandbox だけ |
| 今の仕組みの跡 | prime-pick と、quiz・visionOS のテンプレートに、ralph-kit のスクリプトと `close-goal-discussion.yml` が残る |
| テンプレート | template-app-visionos は develop の Build が 2026-10-21 から落ちたまま。quiz・visionOS は、11-11 以降の直し（`askhub/` への読み替え・ドキュメントだけでも Build・main で Archive しない）が入っていない |

ほかに気づいたこと（この設計の範囲の外）: tm-family/kobuta-tap-ios の `repo.json` のビルドの設定が、改名する前の `TinyPigTap.xcodeproj` のまま。

## 決めたこと

2026-11-22 にユーザーが決めた。

| 決めたこと | 決定 | 採らなかった案 |
| --- | --- | --- |
| App Store の素材のワークフロー（掲載文・掲載文の確かめ・クリエイティブ素材）と Python の道具 | app-kit に入れず、司令塔に寄せる。app-kit に入れるのは Build・Upload/Archive・スクショの撮影だけ。クリエイティブ素材は、司令塔で作れるようになるまで各リポジトリに残す | 今の形のまま全部入れる（司令塔と二重になる）／最初の版は Build と Upload だけ（撮影のずれが残る） |
| 版を上げるときの人の承認 | 版ごとに 1 回。人が変更点を見て押すと、司令塔が試しの 1 本 → 残りの順に PR を出し、CI が通ればマージする。初めての入れ替え（今のワークフローを外すもの）だけは、リポジトリごとに承認する | リポジトリごとに承認／版ごと＋リポジトリごと |
| SwiftLint・CodeRabbit・Issue/PR のテンプレート・CLAUDE.md | CLAUDE.md のほかは、ワークフローと同じ PR で写してそろえる。CLAUDE.md は配らない（リポジトリの事実なので。テンプレートに `## 全員向けの事実` の骨組みだけ置く） | CLAUDE.md にも共通の節を配る／配らない |
| テンプレートとの関係 | テンプレートのリポジトリ（template-app-ios・template-app-visionos）を残し、配る相手にする。中身はアプリの骨組みだけにする。template-quiz-app-ios は配る相手に入れず、そのまま置く | app-kit に骨組みを持ち、テンプレートを上書きする／テンプレートをやめ、司令塔が app-kit から作る |

この設計で決めた既定（承認のときに一緒に確かめる）:

- 共通リポジトリは `shilokuma-inc/app-kit`（public）。作るのは、実装に入るときにユーザーに確かめてから
- 呼ぶ側は、版をタグではなくコミット（40 桁）で固定し、横にタグを書く（`@<コミット> # v1.2.0`）。app-kit のタグはルールセットで動かせない・消せないようにする（[security.md](security.md) の「共通リポジトリのワークフローは、動くタグではなく固定したコミットで呼ぶ」）
- Secrets は、呼ぶ側のワークフローで名前を並べて渡す（`secrets: inherit` は使わない）。`inherit` は同じ organization（か同じ enterprise）の中でしか効かず、対象は 5 つの organization にまたがるため
- 試しの 1 本は tm-family/shinkeisuijaku-app-ios（テンプレートに一番近く、Upload が動き、内部テスターの直しが一番新しい）。司令塔の設定で替えられる

## 共通リポジトリ（shilokuma-inc/app-kit）

### 置くもの

| 種類 | 中身 | 各リポジトリへの届け方 |
| --- | --- | --- |
| 再利用ワークフロー | `app-build.yml`（ビルド・SwiftLint・Unit テスト・UI テスト）、`app-archive.yml`（Archive・IPA の書き出し・App Store Connect への Upload）、`app-store-screenshots.yml`（スクショの撮影だけ。上げない） | 呼ぶ（各リポジトリには呼ぶ側の薄いファイルだけ） |
| ワークフローの道具 | 今の `.github/scripts/*.rb`（アプリがあるかの確かめ・内部テスター）、entitlements を入れる道具、撮影の道具（`capture_screenshots.sh`・`derive_screenshots.py`・`remove_alpha.swift`・`overlay_screenshot.swift`） | 再利用ワークフローが、呼ばれた版の app-kit を取り出して使う（各リポジトリには置かない） |
| 写すファイル | 呼ぶ側のワークフロー（`build.yml`・`upload.yml`・`archive.yml`・`app-store-screenshots.yml`）、`.swiftlint.yml`、`.coderabbit.yaml`、Issue・PR のテンプレート | 司令塔が版の中身に置き換える PR を出す |
| 変更点 | `CHANGELOG.md`（版ごとの変更点。クライアントの「広げる」の画面に出す） | — |

### 置かないもの

- App Store の素材のワークフローと Python の道具（決めたこと）。各リポジトリから外す。クリエイティブ素材だけは、司令塔で作れるようになるまで各リポジトリに残す（配る対象にも、外す対象にも入れない）
- リポジトリだけのワークフロー（kobuta-tap の Game Center・App 内課金、OshiCon の課金の登録、ask-hub-apple の `no-ai-attribution.yml` など）。写すファイルにも外すファイルにも入れず、触れない
- CLAUDE.md・`Configs/*.xcconfig`・`AppStore/` の中身（言語・撮る画面など）。リポジトリの値なので配らない
- Swift のコード。今は配る Swift のコードが無い。撮影モード（`ScreenshotDemo`）など、複数のアプリで同じ Swift のコードを持つようになったら、app-kit とは別の Swift Package にするかを、そのときに決める（prime-pick-ios はもう自前の `quiz-kit` を使っている）

### リポジトリの作り

```
app-kit/
  .github/workflows/
    app-build.yml              # 再利用ワークフロー（workflow_call）
    app-archive.yml
    app-store-screenshots.yml
    self-test.yml              # app-kit 自身の確かめ（下の「app-kit 自身の確かめ」）
  tools/                       # 再利用ワークフローが使う道具
  managed/                     # 写すファイル。各リポジトリでの置き場所と同じ並び
    .github/workflows/build.yml
    .github/workflows/upload.yml
    .github/workflows/archive.yml
    .github/workflows/app-store-screenshots.yml
    .github/ISSUE_TEMPLATE/…
    .github/pull_request_template.md
    .swiftlint.yml
    .coderabbit.yaml
  manifest.json                # 写すファイルの一覧と、初めての入れ替えで外すファイル
  schema/app-kit.schema.json   # 各リポジトリの設定（.github/app-kit.json）の形
  fixtures/App/                # 確かめ用の小さなアプリ
  CHANGELOG.md
```

- 再利用ワークフローは GitHub の決まりで `.github/workflows/` に置く。app-kit 自身の CI と名前がぶつからないよう、配るものには `app-` を付ける
- `managed/` の呼ぶ側のワークフローは、版を `{{APP_KIT_REF}}`（コミット）・`{{APP_KIT_VERSION}}`（タグ）の目印で持ち、司令塔が写すときに埋める。ほかの写すファイルは版の中身そのまま
- `manifest.json` は、写すファイルのパスの一覧（`managed`）と、初めての入れ替えで外すファイル（`replaces`。`_build.yml`・`_archive.yml`・`.github/scripts/*.rb`・App Store の素材のワークフローと道具・今の仕組みの跡）を持つ。司令塔は、この一覧に無いファイルに触れない
  - 外すファイルには、残す条件（`keepIfPresent`）を持たせられる。クリエイティブ素材のワークフローが残るリポジトリでは、それが使う `Tools/app_store_config.py`・`app_store_connect.py`・`remove_alpha.swift` を外さない
  - 版を埋めた写すファイルは `tools/render-managed.sh <コミット> <タグ> <出力のフォルダ>` で作れる（司令塔は同じことを Swift で行う。手で入れ替えるときにも使う）

### 各リポジトリの設定（`.github/app-kit.json`）

再利用ワークフローが、呼んだリポジトリの checkout から読む。呼ぶ側のワークフローはどのリポジトリでも同じ中身にし、リポジトリごとの値はこのファイルだけに持つ（版を上げる PR は、写すファイルをまるごと置き換えるだけになる）。

```json
{
  "v": 1,
  "project": "Shinkeisuijaku.xcodeproj",
  "scheme": "Shinkeisuijaku",
  "platforms": ["iOS"],
  "generate": null,
  "uiTests": "ShinkeisuijakuUITests",
  "xcodeVersion": null,
  "archive": { "platforms": ["iOS"], "googleServiceInfo": null },
  "unmanaged": []
}
```

- `project`・`scheme`: 今は「プロジェクトと同じ名前の共有スキーム」を決め打ちにしている。改名したリポジトリやスキームの名前が違うリポジトリでも動くよう、書いて持つ
- `platforms`: ビルドとテストの行き先（`iOS`・`macOS`・`visionOS`）。`generate` は XcodeGen で作るリポジトリの `"xcodegen"`（ワーカーのビルドの設定の `generate` と同じ）
- `uiTests`: UI テストのターゲット。作業ブランチへの push では飛ばす（今と同じ）。無いリポジトリは `null`
- `xcodeVersion`: 版の既定（今は 26.6）と違う Xcode を使うときだけ書く
- `archive`: Upload する行き先（`platforms`。省くと `platforms` の先頭）と、Secret から書き出す `GoogleService-Info.plist` のパス（`googleServiceInfo`。kobosu。使わなければ `null`）
- `unmanaged`: 写すファイルのうち、このリポジトリでは配らないもの（ask-hub-apple の `.coderabbit.yaml`・`.swiftlint.yml` のように、リポジトリで足した設定があるもの）。版を上げる PR でも、ずれの点検でも触れない
- `.github/` の下なので、ワーカーの epic で変えると、マージの規則で人の確認に回る（[flows.md](flows.md) の「マージの規則」）
- ワーカーのビルドの設定（`repo.json` の `build.xcode`）と値が重なる。初めての入れ替えでは、ビルドの設定から作る。食い違いは、ずれの点検で知らせる

### 再利用ワークフロー

- 呼ぶ側の例（`managed/.github/workflows/upload.yml` を写したもの）:

  ```yaml
  jobs:
    upload:
      if: vars.ENABLE_DELIVERY != 'false'
      uses: shilokuma-inc/app-kit/.github/workflows/app-archive.yml@<コミット> # v1.0.0
      with:
        app-kit-ref: <コミット>
        upload: true
      secrets:
        APPLE_API_KEY_BASE64: ${{ secrets.APPLE_API_KEY_BASE64 }}
        APPLE_API_KEY_ID: ${{ secrets.APPLE_API_KEY_ID }}
        APPLE_API_ISSUER_ID: ${{ secrets.APPLE_API_ISSUER_ID }}
        EXPORT_OPTIONS: ${{ secrets.EXPORT_OPTIONS }}
        TESTFLIGHT_INTERNAL_TESTERS: ${{ secrets.TESTFLIGHT_INTERNAL_TESTERS }}
        GOOGLE_SERVICE_INFO_PLIST_BASE64: ${{ secrets.GOOGLE_SERVICE_INFO_PLIST_BASE64 }}
  ```

- 呼ぶ側のジョブの名前は今と同じにする（`build.yml` のジョブは `build`、再利用ワークフローのジョブも `build`）。チェックの名前は `build / build` のままで、ルールセットとビルドの設定の `childChecks`・`finalChecks` を変えなくてよい
- 道具の取り出し: 再利用ワークフローの中の `github` の値は呼んだ側のもので、呼ばれた版のコミットを知る組み込みの値が無い。そのため、呼ぶ側が同じコミットを `app-kit-ref` で渡し、再利用ワークフローがその版の app-kit を `$RUNNER_TEMP` に取り出す（public なのでトークンは要らない。`persist-credentials: false`）。`uses:` のコミットと `app-kit-ref` は司令塔が同じ値で書き、食い違いはずれの点検で見つける
- Build には Secrets を渡さない。Upload にだけ App Store Connect の鍵を渡す（今と同じ。public のリポジトリで、ワーカーの push から Secrets に届かないように。[security.md](security.md) の「public のリポジトリと Secrets」）
- 起動の条件（push・PR・`askhub/` の子 PR と最終 PR の見分け・`concurrency`）は、呼ぶ側のワークフローに書く（再利用ワークフローからは決められないため）。中身は今のテンプレートと同じで、`paths`・`paths-ignore` で絞らない
- 撮影の呼ぶ側（`app-store-screenshots.yml`）は、ファイルの名前と入力（`display_types`・`languages`・`allow_non_release`・`upload`）を今のままにする。司令塔がこの名前で起動し、artifact `screenshots-<表示サイズ>` を取り込むため（[store-screenshots.md](store-screenshots.md)）。上げるのは司令塔なので、`upload` が true なら理由を出して止める
- 使うアクション（`actions/checkout`・`maxim-lobanov/setup-xcode` など）は、コミットで固定する（今はタグ）
- visionOS（テンプレート）の Archive・Upload も、`archive.platforms` で扱う。macOS（ask-hub-apple）の Archive は v1 では扱わず、ask-hub-apple を入れ替えるときに足す
- 書き出した IPA は artifact に上げない（今のテンプレートは上げている。public のリポジトリでは誰でも取れるため。[release.md](release.md) の「ワークフロー」）

### 版

- 版は `v<major>.<minor>.<patch>`。呼ぶ側を直さないと動かない変更（入力・Secrets の名前・設定の形の変更）は major を上げる。司令塔は、major が違う版を、初めての入れ替えと同じくリポジトリごとの承認で入れる（版ごとの 1 回の承認では広げない）
- タグは、app-kit の develop にマージした後に、`CHANGELOG.md` に変更点を書いてから付ける。タグはルールセットで、動かす・消すを禁止する
- 司令塔は、app-kit のタグを `git ls-remote --tags` で読む（REST の上限に数えない）。変更点は、そのタグの `CHANGELOG.md` を読む

### app-kit 自身の確かめ

- `self-test.yml` が、PR と develop への push で、`fixtures/App`（iOS の小さなアプリ）に対して、同じリポジトリの再利用ワークフロー（`./.github/workflows/app-build.yml`）と、Upload しない Archive（書き出しまで。鍵が要らない所まで）を流す
- 写すファイルの目印が埋まること、`manifest.json` と `managed/` の中身が合うこと、`schema/` の形で `fixtures/` の設定が読めることを確かめる
- 本物のリポジトリでの確かめは、試しの 1 本で行う（下の「版を広げる」）

### app-kit の開発

- ワーカーのトークンは Workflows を持たないので、app-kit の `.github/workflows/` を AskHub の epic では直せない。app-kit は AskHub の対象に入れず、人の Claude Code のセッションで直す
- 保護は、対象のリポジトリと同じルールセット（PR 必須・例外なし）と、タグのルールセット。CodeRabbit は shilokuma-inc に入っているので使う
- 直しは app-kit で行う。各リポジトリで直したくなったら、app-kit に直しを入れて版を上げる（リポジトリで直すと、次に版を上げたときに上書きされる。上書きされたくないファイルは `unmanaged` に書く）

## 各リポジトリへの届け方

どちらも、司令塔が管理用のトークンで PR を出し、マージする（[security.md](security.md) の「管理用のトークン」）。ワーカーのトークンは Workflows を持たないので、ふだんの epic では出せない。

### 初めての入れ替え

「対象に加える」の GitHub 側の準備（#1096 の、司令塔が出すワークフローの直しの PR と、人の承認 `approveSetupPullRequest`）に足す。今あるリポジトリは、クライアントの「準備をやり直す」で同じ手順を流す（[plan.md](plan.md) の「今あるリポジトリにも『対象に加える』と同じ手順を流してそろえる」）。

1. 司令塔が、そのとき広げている版の app-kit を読み、PR の中身を作る
   - `.github/app-kit.json` を足す。値はビルドの設定（`repo.json` の `build`）と、リポジトリのファイル（UI テストのターゲット・Upload の行き先）から作る
   - 写すファイルを版の中身にする（`unmanaged` は除く）
   - `manifest.json` の `replaces` にあるファイルを外す。ワークフローを外すと、その中にしか無かったリポジトリだけの手順も消えるので、PR の本文に外すファイルごとの差分の大きさと、テンプレートに無かった手順の見出しを並べる
2. 人がクライアントで PR の中身（外すもの・足すもの）を見て承認する（リポジトリごと）。見たときの head に結びつけ、承認の後に push されたらマージしない（#1096 と同じ）
3. 必須のチェックが通ったら、司令塔が merge commit でマージし、`repo.json` の `appKit` に版を書く
4. チェックの名前が変わるリポジトリ（prime-pick-ios の `Build`、askhub-sandbox の `build`）は、入れ替えた PR に古い名前のチェックが出ないので、そのままではマージできない。承認の画面に「必須のチェックを `Build` から `build / build` に替える」と出し、承認されたら、司令塔がマージの前にルールセットの必須のチェック（保護を掛けていれば）とビルドの設定の `childChecks`・`finalChecks` を新しい名前に替える
5. 外したワークフローにしか無かった手順（リポジトリだけの Secret の扱いなど）で要るものは、`.github/app-kit.json` の欄に足すか（app-kit の版を上げる）、リポジトリだけのワークフローとして残す。どちらにするかは、入れ替えの PR を見て決める（今の 8 本の分は、下の「今あるリポジトリをそろえる手順」）

### 版を広げる

1. 司令塔が app-kit の新しいタグを見つけたら、状態リポジトリに版と変更点を書く。クライアントのリポジトリの画面に「app-kit v1.1.0 が出ました」と変更点、リポジトリごとの今の版を出す
2. 人が変更点を見て「広げる」を押す（版ごとに 1 回の署名した意図。版のタグとコミットに結びつける）
3. 司令塔が、試しの 1 本に、写すファイルを新しい版に置き換える PR を出す（ブランチ `askhub/app-kit-v1.1.0`）。必須のチェックが通ったらマージし、マージした後の develop の Build（Archive・Upload を変えた版なら Upload も）が通るのを待つ
4. 試しの 1 本が通ったら、残りの対象のリポジトリに同じ PR を出し、それぞれ必須のチェックが通ったらマージする。最後にテンプレートに出す
   - PR の中身は、写すファイルを版の中身に置き換えるだけで、ほかのファイルを変えない。違う中身になったら（リポジトリで写すファイルを直していたなど）、マージせずに止めて人に見せる
   - 上限（GitHub の 1 時間の上限と、司令塔の書き込みの予算）を食わないよう、PR は一度に 1 本ずつ出す
5. 失敗したら（CI が落ちた・30 分たってもチェックが出ない・コンフリクト）、そのリポジトリは PR を開いたまま止め、理由をクライアントに出す。試しの 1 本で失敗したら、残りには出さない。人は「もう一度試す」か「やめる」（PR を閉じる）を選ぶ
6. 戻すときは、前の版を同じ手順で広げる

- 対象から外したリポジトリ（`removedAt`）と、終わっていない入れ替えの PR があるリポジトリには出さない
- 同じリポジトリで epic が動いていても出す（写すファイルは epic の作業ブランチとぶつからない。作業ブランチの CI は、作業ブランチに base を取り込むまで前の版のまま動く）

### 状態リポジトリに書くもの

形は実装の PR で決め、[protocol.md](protocol.md) に書く。今の考え:

- `repo.json` の `appKit`（今は `{ "ref" }` だけ）に、版のタグ・コミット・入れた時刻・開いている PR（番号・head・入れ替えか版の上げか）・ずれ（`drift`。`protection.drift` と同じ形）を持たせる
- 状態リポジトリの直下の `app-kit.json` に、見つけた版（タグ・コミット・変更点）と、広げている版の進み具合（リポジトリごとの様子）を持たせる
- 意図: 版を広げる（`rolloutAppKit`。版のタグとコミット）・広げるのをやめる。初めての入れ替えの承認は `approveSetupPullRequest` を使い、準備の結果（`repo.json` の `setup.workflows.changes`）の変更の種類に、app-kit への入れ替え（`adoptAppKit`）を足す

### ずれの点検

- 保護のずれの点検（[operations.md](operations.md) の「保護の設定」）と同じく、6 時間ごとに毎日のトークンで読む（管理用のトークンは自動では使わない）
- 見るもの: 写すファイルが `appKit` の版の中身と同じか、呼ぶ側の `uses:` のコミットと `app-kit-ref` が `appKit` のコミットと同じか、`.github/app-kit.json` の `project`・`scheme` がビルドの設定と合うか
- ずれは `appKit.drift` に書き、クライアントに出す。直すのは、人が版を広げ直したとき（同じ版を広げると、置き換える PR を出す）

## テンプレート

- template-app-ios と template-app-visionos を、対象のリポジトリと同じく配る相手にする。初めての入れ替えはリポジトリごとの承認で、版を広げるときは最後に出す
- テンプレートは AskHub の対象（`repos/`）ではないので、司令塔の設定にテンプレートの一覧を持つ（テンプレートからの新規作成で使う一覧と同じものにする）
- テンプレートに残すのは、アプリの骨組み（プロジェクト・画面の雛形・`AppStore/` の雛形・撮影モード）と、`.github/app-kit.json`・写すファイル・`## 全員向けの事実` の見出しだけの CLAUDE.md
- テンプレートから作ったリポジトリは、テンプレートの版の app-kit を呼ぶ形で生まれる。「対象に加える」で、呼ぶ側のコミットを読んで `appKit` に書く。名前を置き換えるとき（テンプレートからの新規作成の処理）は、`.github/app-kit.json` の `project`・`scheme` も置き換える
- template-app-visionos の develop の Build は落ちたままなので、入れ替えのときに直す
- template-quiz-app-ios は配る相手に入れず、そのまま置く（今の仕組みの跡も残る。使うときに決める）

### テンプレートからの新規作成（段階 4 の 5）との分担

段階 4 の 5（別のセッション。テンプレートからの新規作成）と同じ時期に進むので、次のように分ける。

- テンプレートから今の仕組みの跡を外すのは、段階 4 の 5 が先に行う。app-kit への入れ替えは、その PR がマージされてから出す
- テンプレートの一覧と、テンプレートから作ってから名前を置き換える処理は、段階 4 の 5 が持つ。app-kit は `.github/app-kit.json` の名前の欄を足すだけ
- テンプレートの中身（`.github/` と骨組み）を変える PR を出す前に、段階 4 の 5 の PR と共有ノートを読み、ぶつからないようにする

## 今あるリポジトリをそろえる手順

最初の入れ替えは、司令塔の仕組みができる前に、試しの 1 本だけを人の Claude Code のセッションで手で行い、app-kit の最初の版を本物で確かめる（下の「実装の順と PR の分け方」の 6）。残りは、司令塔の仕組みができてから、クライアントの「準備をやり直す」で行う。

| 順 | リポジトリ | 入れ替えで見ること |
| --- | --- | --- |
| 1 | tm-family/shinkeisuijaku-app-ios（試しの 1 本） | テンプレートに一番近い。Upload と内部テスター（このリポジトリの直しが一番新しいので、app-kit にはこちらを入れる）が動くか |
| 2 | template-app-ios・template-app-visionos | 段階 4 の 5 の跡を外す PR の後。visionOS の Build を直す |
| 3 | tm-family/kobosu-app-ios・tm-family/kobuta-tap-ios | kobosu は `GoogleService-Info.plist`（`archive.googleServiceInfo`）。kobuta-tap は先にビルドの設定の名前（`KobutaTap`）を直す。Game Center・App 内課金のワークフローは残す |
| 4 | BeaconFun4/demomoni-remake-ios | App Store の素材のワークフローが無い。古い `_archive.yml`（スタブの直しが無い）を入れ替える |
| 5 | shariverse/oshikatsu-countdown-ios | 独自の掲載文のワークフロー（±360）と Ruby の道具は、司令塔に寄せるので外す。課金の登録のワークフローは残す。ウィジェットの拡張がある |
| 6 | shilokuma-inc/askhub-sandbox | Upload が無い（`ENABLE_DELIVERY` を false に）。チェックの名前が `build` から変わる。既定のブランチが main |
| 7 | shilokuma-inc/prime-pick-ios | 古い 3 本立て。チェックの名前が `Build` から変わる。今の仕組みの跡（ralph-kit・`close-goal-discussion.yml`）を外す。Firebase・AdMob。手動の署名（証明書と provisioning profile を Secrets に置く）を、自動の署名にそろえる（[plan.md](plan.md) の「残りのリポジトリの移し方」） |
| 8 | shilokuma-inc/ask-hub-apple | iOS と macOS。撮影（macOS の撮影を含む）・掲載文の独自の直しが一番多い。`.coderabbit.yaml`・`.swiftlint.yml` は `unmanaged`。最後にする |

- 入れ替えたら、そのリポジトリの App Store の素材のワークフロー（掲載文・確かめ）は外れる。掲載文は司令塔の流れ（[release.md](release.md) の「掲載文」）で直す
- 対象に入っていないリポジトリ（今の仕組みで管理していたもの）は、「対象に加える」ときに同じ手順で入れ替わる

## 実装の順と PR の分け方

それぞれ独立してマージでき、司令塔の部品は、版を広げる意図が来るまで今の動きを変えない。

| 順 | どこ | PR | 中身 |
| --- | --- | --- | --- |
| 0 | ask-hub-apple | この設計の文書（#1210） | |
| 1 | GitHub | — | `shilokuma-inc/app-kit` を作る（ユーザーに確かめてから）。public・既定のブランチは develop・ルールセット（ブランチとタグ）・CodeRabbit |
| 2 | app-kit | (a) | 骨組み・`app-build.yml`・`.github/app-kit.json` の形（`schema/`）・`fixtures/App`・`self-test.yml` |
| 3 | app-kit | (b) | `app-archive.yml` と道具（アプリがあるかの確かめ・スタブの署名の直し・entitlements・内部テスター・`GoogleService-Info.plist`）。今のリポジトリの一番新しい直しを集める |
| 4 | app-kit | (c) | `app-store-screenshots.yml`（撮るだけ。入力と artifact の名前は今のまま）と撮影の道具 |
| 5 | app-kit | (d) | `managed/`（呼ぶ側のワークフロー・SwiftLint・CodeRabbit・Issue/PR のテンプレート）と `manifest.json`。`CHANGELOG.md` を書き、v1.0.0 のタグを付ける |
| 6 | shinkeisuijaku-app-ios | 試しの入れ替え | 人の Claude Code のセッションで手で入れ替え、Build・Upload・撮影（`allow_non_release`）を本物で流す。ワークフローの変更なので、ユーザーがマージする。直しが要れば app-kit の v1.0.x にする |
| 7 | ask-hub-apple | プロトコル | `repo.json` の `appKit`・状態の `app-kit.json`・意図 `rolloutAppKit`・準備の変更の種類 `adoptAppKit`（スキーマ・ベクタ・Swift の型・protocol.md） |
| 8 | ask-hub-apple | 司令塔: 入れ替え | 準備の PR（#1096）に app-kit への入れ替えを足す。#1096 のマージが前提 |
| 9 | ask-hub-apple | 司令塔: 版とずれ | 版を読む・版を広げる（試しの 1 本 → 残り → テンプレート）・ずれの点検 |
| 10 | ask-hub-apple | クライアント | リポジトリの画面に版・ずれ・入れ替えの中身と承認、新しい版の変更点と「広げる」、広げている進み具合 |
| 11 | 運用 | — | 上の「今あるリポジトリをそろえる手順」の 2〜8 を、クライアントの「準備をやり直す」で行う |

- 文書（operations.md・protocol.md・release.md）と LEARNINGS.md は、各 PR で変えた所を直す
- 司令塔の変更をマージしたら、常時オンの Mac の司令塔を更新する（[operations.md](operations.md) の「司令塔の更新」）

## 決めずに残すこと

- XcodeGen への移行（段階 5 の 7）。app-kit は `generate` で XcodeGen のリポジトリも扱えるようにしておき、テンプレートを XcodeGen にするかは段階 5 の 7 で決める
- 複数のアプリで同じ Swift のコードを持つようになったときの Swift Package（上の「置かないもの」）
- クリエイティブ素材のワークフロー。司令塔でプロダクトページのヘッダー・検索結果の素材を作れるようになったら、各リポジトリから外す（[release.md](release.md) の「プロダクトページのヘッダーと検索結果の素材」）
- Upload の鍵を Environment の Secrets に移すこと（#1067）。移すときは、app-kit の `app-archive.yml` の `environment` と、呼ぶ側の Secrets の渡し方を一緒に変える（major を上げる）
- Android のリポジトリ（段階 6）。同じ形（再利用ワークフロー・写すファイル・版を広げる）で、別の再利用ワークフローを足す見込み
