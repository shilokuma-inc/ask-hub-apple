# 共通リポジトリ（app-kit）とテンプレート

[plan.md](plan.md) の段階 5 の 5「共通リポジトリ（app-kit）とテンプレートの作り直し・配布」の設計（#1210）。
元の方針は [operations.md](operations.md) の「共通リポジトリとテンプレートの配布」。この文書は、その方針を作れる形まで決める。

状態: 2026-11-22 にユーザーが決め、設計を承認した（下の「決めたこと」）。同じ日に `shilokuma-inc/app-kit` を作り、v1.0.0 を出した（下の「実装の順と PR の分け方」の 1〜5。app-kit の #2・#4・#6・#8・#10）。試しの 1 本の入れ替えは tm-family/shinkeisuijaku-app-ios#83。
macOS のアプリの Archive・Upload は、2026-11-23 にユーザーが決め、app-kit の v1.4.0 で足す（下の「macOS のアプリ」。app-kit#21）。
App Extension などの中のバンドルの entitlements は、2026-11-24 にユーザーが決め、app-kit の v1.5.0 で足す（下の「App Extension の entitlements」。app-kit#23）。
既定の Xcode は、2026-11-24 に app-kit の v1.8.0 で 26.6 から 27.1 に上げる（下の「Xcode 27」。app-kit#29）。

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
  - 審査の提出のワークフロー（`app-store-submit.yml`。shilokuma-vision/theater-player-app-vision）が残るリポジトリでは、`Tools/submit_for_review.py` が読む `Tools/app_store_config.py`・`app_store_connect.py`・`upload_app_info.py`・`upload_metadata.py` を外さない（v1.6.0。下の「構成の切り替えと Firebase」）
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
  - プラットフォームでスキームが違うアプリ（shilokuma-inc/kawarin-apple の macOS 版の `KawarinMac`）は、`schemes` に違うものだけを書く（v1.6.0。下の「プラットフォームごとのスキーム」）
- `platforms`: ビルドとテストの行き先（`iOS`・`macOS`・`visionOS`）。`generate` は XcodeGen で作るリポジトリの `"xcodegen"`（ワーカーのビルドの設定の `generate` と同じ）
- `uiTests`: UI テストのターゲット。作業ブランチへの push では飛ばす（今と同じ）。無いリポジトリは `null`
- `xcodeVersion`: 版の既定（v1.7.0 までは 26.6、v1.8.0 から 27.1）と違う Xcode を使うときだけ書く。ランナーは Xcode の major で決まる（下の「Xcode 27」）
- `archive`: Upload する行き先（`platforms`。省くと `platforms` の先頭）と、Secret から書き出す `GoogleService-Info.plist` のパス（`googleServiceInfo`。kobosu。使わなければ `null`）。構成をブランチで切り替えるアプリは `configurations` を書く（下の「構成の切り替えと Firebase」）
- `unmanaged`: 写すファイルのうち、このリポジトリでは配らないもの（ask-hub-apple の `.coderabbit.yaml`・`.swiftlint.yml` のように、リポジトリで足した設定があるもの）。版を上げる PR でも、ずれの点検でも触れない
- `.github/` の下なので、ワーカーの epic で変えると、マージの規則で人の確認に回る（[flows.md](flows.md) の「マージの規則」）
- ワーカーのビルドの設定（`repo.json` の `build.xcode`）と値が重なる。初めての入れ替えでは、ビルドの設定から作る。食い違いは、ずれの点検で知らせる

### 構成の切り替えと Firebase（v1.6.0）

2026-11-24 にユーザーが決めた。shariverse/dokogacha-app-ios を入れ替えるため（案: app-kit に足す／dokogacha の Archive をリポジトリだけのワークフローとして残す → app-kit に足す）。
v1.6.0 は、App Extension の entitlements（v1.5.0。app-kit#24・#1255）の次の版にする。

- わけ: v1.5.0 までの Archive は `-configuration Release` 決め打ちで、`GoogleService-Info.plist` は Secret `GOOGLE_SERVICE_INFO_PLIST_BASE64` の 1 つだけを `archive.googleServiceInfo` に書き出す。
  dokogacha は develop の TestFlight を Stg（Bundle ID `jp.shilokuma.Dokogacha.stg`、App Store Connect では別のアプリ。Firebase は dev）、`release/**` と main を Release（Firebase は prod）で作り、dSYM を Crashlytics に上げている。
  そのまま入れ替えると、develop の Upload が本番のアプリに Firebase に繋がらないビルドを上げ、Crashlytics の記号化も止まる
- 設定は `archive.configurations`（並び）と `archive.crashlytics`:

  ```json
  "archive": {
    "platforms": ["iOS"],
    "configurations": [
      {
        "name": "Release",
        "branches": ["main", "release/*"],
        "googleServiceInfo": { "path": "Dokogacha/Resources/Firebase/GoogleService-Info-Prod.plist", "secret": "GOOGLE_SERVICE_INFO_PLIST_PROD", "required": true }
      },
      {
        "name": "Stg",
        "googleServiceInfo": { "path": "Dokogacha/Resources/Firebase/GoogleService-Info-Dev.plist", "secret": "GOOGLE_SERVICE_INFO_PLIST_DEV" }
      }
    ],
    "crashlytics": true
  }
  ```

  - `name`: Archive するビルドの構成（`xcodebuild -configuration`）。entitlements を展開するときの構成も同じにする
  - `branches`: その構成で Archive するブランチのパターン（`*` は `/` もまたぐ）。上から順に見て、最初に合ったものを使う。`branches` の無いものはどのブランチにも合う（最後に 1 つだけ置ける）。どれにも合わなければ、理由を出して止める
  - 手動の実行（`archive.yml`・`upload.yml` の `workflow_dispatch`）は、入力 `configuration` で構成の名前を選べる。空ならブランチで決める
  - `googleServiceInfo.path`: 書き出す先（リポジトリの直下から。ファイル名は `GoogleService-Info` で始まる `.plist`）。`secret`: 読む Secret。再利用ワークフローの Secrets は名前を決めて渡すので、`GOOGLE_SERVICE_INFO_PLIST_BASE64`・`GOOGLE_SERVICE_INFO_PLIST_DEV`・`GOOGLE_SERVICE_INFO_PLIST_PROD` のどれかに限る
  - `required`: true なら、Upload するときに Secret が無ければ止める（Firebase に繋がらないビルドを App Store 用に出さない）。false（既定）なら、今と同じく注釈を出して進む
  - Archive の後に、書き出した plist がアプリに入ったか、ほかの構成の plist が入っていないかを確かめる（取り違えて本番のアプリが dev に繋がらないように）
  - `configurations` が無ければ、今と同じ（Release と `archive.googleServiceInfo`・`GOOGLE_SERVICE_INFO_PLIST_BASE64`）。`configurations` と `archive.googleServiceInfo` を両方書いたら断る
- `crashlytics`: true なら、Upload するときに、書き出した plist で dSYM を Crashlytics に上げる（SPM が取ってきた firebase-ios-sdk の `Crashlytics/upload-symbols`）。plist が無い・道具が無い・失敗したときは、注釈を出して Upload は止めない
- 呼ぶ側（`upload.yml`・`archive.yml`）は、Secrets に `GOOGLE_SERVICE_INFO_PLIST_DEV`・`_PROD` を足し、入力 `configuration` を足す。今の設定はそのまま動くので minor にする
- 司令塔の初めての入れ替えは、`.github/app-kit.json` があれば変えない。dokogacha は、準備をやり直す前に、リポジトリに上の形の `.github/app-kit.json` を入れておく
- 審査の提出の道具: `manifest.json` の `replaces` の `Tools/app_store_config.py`・`app_store_connect.py`・`upload_app_info.py`・`upload_metadata.py` に、`keepIfPresent` として `.github/workflows/app-store-submit.yml`・`Tools/submit_for_review.py` を足す（theater-player の Submit/App Store が読む。審査の提出を司令塔に寄せたら外す）

### プラットフォームごとのスキーム（v1.6.0）

2026-11-24 にユーザーが決めた。shilokuma-inc/kawarin-apple は、iOS 版がスキーム `Kawarin`、macOS 版が別のターゲットとスキーム `KawarinMac`（製品は同じ `Kawarin.app`、Bundle ID も同じ）で、v1.5.0 までの app-kit は 1 つの `scheme` でしか Build・Archive できない。構成の切り替えと同じ版に入れる（app-kit の書き手を重ねないため）。

- 設定は `schemes`（プラットフォーム → スキーム）。`scheme` と違うプラットフォームだけを書く。書かないプラットフォームは `scheme` を使う

  ```json
  { "project": "Kawarin.xcodeproj", "scheme": "Kawarin", "schemes": { "macOS": "KawarinMac" }, "platforms": ["iOS", "macOS"], "archive": { "platforms": ["iOS", "macOS"] } }
  ```

- キーは `platforms` にあるプラットフォームだけ。値はスキームの形（`scheme` と同じ）
- Build: テストは先頭のプラットフォームのスキームで流す（`uiTests` もそのスキームのもの）。2 つ目からのプラットフォームは、それぞれのスキームでビルドだけを確かめる。パッケージの解決と SwiftLint は `scheme` で行う（同じプロジェクト）
- Archive・Upload: プラットフォームごとのジョブが、そのプラットフォームのスキームで Archive し、entitlements もそのスキームの設定で入れる。App Store Connect のアプリの確かめの名前は `scheme` のまま
- 司令塔のずれの点検・初めての入れ替えで比べるのは、今までどおり `scheme`（ワーカーのビルドの設定のスキーム）だけ

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
- visionOS（テンプレート）の Archive・Upload も、`archive.platforms` で扱う。macOS は v1.0.0〜v1.3.0 では扱わず、v1.4.0 で足す（下の「macOS のアプリ」）
- 書き出した IPA・pkg は artifact に上げない（今のテンプレートは上げている。public のリポジトリでは誰でも取れるため。[release.md](release.md) の「ワークフロー」）
- v1.5.0 から、バンドルごとの entitlements の記録（JSON）を artifact `entitlements-<プラットフォーム>` に上げる（下の「App Extension の entitlements」）。配信したアプリからも読める値だけで、IPA・pkg は上げない

### 版

- 版は `v<major>.<minor>.<patch>`。呼ぶ側を直さないと動かない変更（入力・Secrets の名前・設定の形の変更）は major を上げる。司令塔は、major が違う版を、初めての入れ替えと同じくリポジトリごとの承認で入れる（版ごとの 1 回の承認では広げない）
- タグは、app-kit の develop にマージした後に、`CHANGELOG.md` に変更点を書いてから付ける。タグはルールセットで、動かす・消すを禁止する
- 司令塔は、app-kit のタグを `git ls-remote --tags` で読む（REST の上限に数えない）。変更点は、そのタグの `CHANGELOG.md` を読む

### app-kit 自身の確かめ

- `self-test.yml` が、PR と develop への push で、`fixtures/App`（iOS の小さなアプリ）と `fixtures/MacApp`（macOS の小さなアプリ。v1.4.0 から）と `fixtures/ExtensionApp`（ウィジェットを持つ iOS の小さなアプリ。v1.5.0 から。Archive だけ）に対して、同じリポジトリの再利用ワークフロー（`./.github/workflows/app-build.yml`）と、Upload しない Archive（書き出しの手前まで。鍵が要らない所まで）を流す
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

形は [protocol.md](protocol.md)（`repo.json` の `appKit`・`setup.workflows`、`app-kit.json`、意図の表）と `protocol/` にある（#1225）。

- `repo.json` の `appKit` に、版のコミット（`ref`）・タグ（`version`）・入れた時刻（`installedAt`）・ずれ（`drift`。`protection.drift` と同じ形）を持たせる
- 開いている PR は、版の上げの PR を `app-kit.json` の `rollout.targets` に、入れ替えの PR を `setup.workflows` に持つ（テンプレートには `repo.json` が無いので、版の上げの PR を 1 か所にまとめた）
- 状態リポジトリの直下の `app-kit.json` に、見つけた版（タグ・コミット・変更点）、入れ替えに使う版（`adoption`）、広げている版の進み具合（`rollout`。相手ごとの様子）、テンプレートに入っている版（`templates`）を持たせる
- 意図: 版を広げる（`rolloutAppKit`）・広げるのをやめる（`stopAppKitRollout`）。どちらも封筒の `repo` を書かず、target を版のタグ、targetVersion を版のコミットに結びつける。初めての入れ替えの承認は `approveSetupPullRequest` を使い、準備の結果（`setup.workflows`）の変更の種類に、app-kit への入れ替え（`adoptAppKit`）と置き換わるファイルを外す（`removeReplaced`）を足し、入れる版と名前が変わる待つチェックを `setup.workflows.appKit` に持つ

### ずれの点検

- 保護のずれの点検（[operations.md](operations.md) の「保護の設定」）と同じく、6 時間ごとに毎日のトークンで読む（管理用のトークンは自動では使わない）
- 見るもの: 写すファイルが `appKit` の版の中身と同じか、呼ぶ側の `uses:` のコミットと `app-kit-ref` が `appKit` のコミットと同じか、`.github/app-kit.json` の `project`・`scheme` がビルドの設定と合うか
- `appKit` の記録が無いリポジトリも読み、`build.yml` が app-kit を呼んでいれば、呼んでいる版を `appKit` に書く（手で入れ替えたリポジトリ。tm-family/shinkeisuijaku-app-ios は v1.2.0 を手で入れ、記録が無かった。#1299）
- ずれは `appKit.drift` に書き、クライアントに出す。直すのは、人が版を広げ直したとき（同じ版を広げると、置き換える PR を出す）

## テンプレート

- template-app-ios と template-app-visionos を、対象のリポジトリと同じく配る相手にする。版を広げるときは最後に出す
- 初めての入れ替えは、人の Claude Code のセッションで手で行う（2026-11-22 にユーザーが決めた。テンプレートは `repos/` の対象ではないので、クライアントに承認の画面を別に作らずに済ませる）。司令塔は、入れ替え済みのテンプレート（`app-kit.json` の `templates[].appKit` がある）にだけ版を広げる。iOS は template-app-ios#190、visionOS は app-kit に visionOS の撮影を足してから
- テンプレートは AskHub の対象（`repos/`）ではないので、テンプレートの一覧はテンプレートからの新規作成と同じもの（コードの `RepositoryTemplate`。`AppKitPolicy.templates`）を使う
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

## 実装で決めたこと（7〜10）

- 版を広げる・ずれの点検の動きは [operations.md](operations.md) の「共通リポジトリとテンプレートの配布」に書いた（#1227）
- 試しの 1 本の後のほかの相手で止めたら、残りの相手には出し続け、最後に `failed` にする（試しの 1 本で止めたときだけ、残りに出さない）
- ほかの版を広げている途中（`running`・`failed`）に、新しい版は広げない。先に「やめる」を押す
- major が違う版は広げずに飛ばす。major を上げる入れ替え（リポジトリごとの承認）は、major を上げる版が出るまで作らない
- テンプレートの初めての入れ替えは人が手で行う（2026-11-22 にユーザーが決めた）。司令塔は、`build.yml` が app-kit を呼ぶようになったテンプレートを、ずれの点検で見つけて `templates[].appKit` に書き、版を広げる相手にする
- クライアント（#1228。2026-11-22 にユーザーが決めた）: リポジトリのタブの一番上に「app-kit」の行を置き、その画面に新しい版の変更点と「広げる」、広げている進み具合（相手ごとの様子と PR・「もう一度試す」「やめる」）、リポジトリとテンプレートごとの入っている版とずれ、前の版（戻すときに広げる）を出す。各リポジトリの画面には、入っている版・ずれ・広げている版のこのリポジトリの PR を出し、「加えるときの準備」に入れる版と名前が変わる待つチェックを出して承認の確かめに添える
  - あなたの番: 新しい版（まだ広げていない一番新しい版で、それより古い版が入っている相手があるとき）とずれ（リポジトリ・テンプレート）は「時間のあるときに」、広げる途中で止まったことは「進行が止まっています」

## macOS のアプリ

app-kit の v1.4.0 で、macOS（Mac App Store）の Archive・`.pkg` の書き出し・App Store Connect への Upload を足す（#1252・app-kit#21）。
対象は shilokuma-inc/mullion-macos・shilokuma-inc/quick-key-assistant-macos・このリポジトリの macOS 版。設定の形・入力・Secrets の名前は変えないので、minor の版にする。

### 今の 3 本で分かったこと

2026-11-23 に、3 本のワークフローと実行の記録を読んだ（読むだけ）。

| 見たもの | 分かったこと |
| --- | --- |
| Build | app-kit の `app-build.yml` は v1.0.0 から macOS を扱う（先頭が macOS なら、アドホック署名・App Sandbox なしでテスト。2 つ目からは署名なしでビルド）。mullion の `_build.yml` と同じ手順で、mullion の develop では macOS の UI テストも GitHub のランナーで通っている |
| 書き出しと Upload | 3 本とも、iOS と同じ organization の `EXPORT_OPTIONS`（method は iOS と同じ）・API キー・`-allowProvisioningUpdates` のまま、`.pkg` を TestFlight まで上げている。証明書（Apple Distribution・Mac Installer Distribution）と profile は Export が作る。新しい Secrets は要らない |
| Archive の署名 | 3 本とも macOS はアドホック署名（`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER=`）で Archive する。署名なし（`CODE_SIGNING_ALLOWED=NO`）だと `ENABLE_APP_SANDBOX` などのビルドの設定から作られる entitlement が入らず、Export でも足されないので、App Store Connect が App Sandbox の無いアプリとして断る |
| profile の要る entitlement | push（`com.apple.developer.aps-environment`）などがあると、macOS はアドホック署名でも「requires a provisioning profile」で止まる。このリポジトリは、自動の署名のときだけ entitlements のファイルを付け（`Configs/Project.xcconfig`）、Archive の後に `Tools/embed_archive_entitlements.py` がアドホック署名の entitlement に足して署名し直す |
| ビルド番号 | `manageAppVersionAndBuildNumber` は macOS でも効く（mullion・このリポジトリ）。quick-key だけ UTC の日時をビルド番号にしている |
| ほかの癖 | Mac App Store には Info.plist の `LSApplicationCategoryType` が要る。iOS と macOS は App Store Connect の版とビルド番号を別に数える |
| このリポジトリの iOS | iOS の entitlements のファイルが `$(APS_ENVIRONMENT)` を含む。v1.3.0 の app-kit の entitlements の道具は変数を展開しないので、そのままでは書き出しの確かめで落ちる |

### 決めたこと

2026-11-23 にユーザーが決めた（すべて推奨の案）。

| 決めたこと | 決定 | 採らなかった案 |
| --- | --- | --- |
| App Store Connect のアプリに macOS のプラットフォームが無いとき（iOS と macOS を出すアプリ） | macOS の Upload だけを飛ばし、追加の手順を Job Summary に出す（ジョブは成功のまま。このリポジトリの今の動きと同じ）。Archive・書き出しは流してから飛ばす | 手順を出して macOS のジョブを失敗にする |
| entitlements の道具 | このリポジトリの `Tools/embed_archive_entitlements.py` を app-kit に移し、iOS・visionOS・macOS で使う。iOS でも `$(…)` を展開し、アプリのターゲットを製品の名前で選ぶ（v1.3.0 の道具は Scheme の先頭のターゲットの設定を読んでいた） | macOS だけ新しい道具にし、iOS は v1.3.0 のまま |
| macOS のスクショ | v1.4.0 では扱わない（撮れない表示サイズは v1.3.0 から plan で止める） | このリポジトリの「macOS のユニットテストで画面を描いて撮る」方式を、アプリが撮影のテストを持つ約束として取り込む |
| app-kit の確かめ | `fixtures/MacApp`（macOS だけの小さなアプリ）を足し、self-test で Build と Archive（書き出しの手前まで）を流す。本物の確かめは mullion-macos と shinkeisuijaku-app-ios の一時ブランチの Archive（書き出しまで） | 今の fixture を iOS と macOS の両方のアプリにする／fixture を足さない |

### 設定と流れ

- 設定は `platforms`・`archive.platforms` に `macOS` を書くだけ。iOS と macOS を出すアプリは `archive.platforms: ["iOS", "macOS"]` にする。プラットフォームごとに別のジョブ（`archive (iOS)`・`archive (macOS)`）になるので、macOS が落ちても iOS は上がる
- macOS の Archive・Upload だけを止めたいときは `archive.platforms` から外す。app-kit は変数 `ENABLE_MACOS_DELIVERY` を読まない。このリポジトリでこの変数は、macOS の掲載文とスクショの反映も止めているので、それらのワークフローを残すあいだは変数も残す
- `app-archive.yml` の macOS のジョブ:
  1. アドホック署名で Archive する（`-destination 'generic/platform=macOS'`）。スタブのフレームワークの署名の直しは飛ばす（アドホック署名なら、同梱するときに Xcode が署名する）
  2. プロジェクトの既定の署名（自動）で読んだ `CODE_SIGN_ENTITLEMENTS` を、`$(…)` を展開して、アドホック署名の entitlement に足す。足すものが無ければ署名し直さない
  3. Archive のアプリの `com.apple.security.app-sandbox` が `true` か、Info.plist に `LSApplicationCategoryType` があるかを、書き出しの前に確かめる（鍵が要らないので self-test でも流れる）
  4. 書き出した `.pkg` を展開して、Archive の entitlement がすべて残ったかを確かめる
  5. Upload の前に、App Store Connect にアプリがあるか（無ければ作り方を出して止める。iOS と同じ）と、そのアプリに macOS の版があるかを読む。無ければ Upload を飛ばす
- TestFlight の内部テストグループはアプリに 1 つなので、内部テスターは `archive.platforms` の先頭のジョブだけで設定する（2 つのジョブが同時にグループを作らないように）
- profile の要る entitlement を持つ macOS のアプリは、このリポジトリと同じく、アドホック署名（`CODE_SIGN_STYLE=Manual`）のときは entitlements のファイルから外す。Archive の後に app-kit が足す

### 入れ替えるときに要ること

| リポジトリ | 要ること |
| --- | --- |
| mullion-macos | `platforms`・`archive.platforms` を `["macOS"]`、`uiTests` を `MullionUITests`。`AppStore/` が無いので、`unmanaged` に撮影（`app-store-screenshots.yml`）とクリエイティブ（`app-store-creative.yml`）を入れる。Xcode は 26.3 から app-kit の既定（v1.7.0 までは 26.6、v1.8.0 から 27.1）になる。書き出した `.pkg` は artifact に上がらなくなる |
| quick-key-assistant-macos | mullion と同じに加え、`swiftlint` を false にする（SwiftLint を入れていない）。共有の Scheme が無いので、先に作ってコミットする。ビルド番号は UTC の日時から Xcode の採番に替わる（App Store Connect の一番大きい番号から続く） |
| このリポジトリ | `platforms` の先頭だけでテストが流れる（今は iOS と macOS の両方でテストし、`AskHubKit` を `swift test` で確かめる）。撮影（macOS の撮影を含む）と掲載文のワークフローは今のまま残す（`unmanaged`・`replaces` の `keepIfPresent`）。`.coderabbit.yaml`・`.swiftlint.yml` は `unmanaged`。最後にする（上の「今あるリポジトリをそろえる手順」） |

## App Extension の entitlements

app-kit の v1.5.0 で、Archive に entitlements を入れる手順と、書き出した IPA・pkg の確かめを、アプリ本体だけでなく、中の App Extension などのすべてのバンドルに広げる（#1254・app-kit#23）。
v1.4.0 までは本体しか扱わないので、ウィジェットなどの entitlement（App Groups など）が配信ビルドから抜けても Upload まで通る。拡張を持つアプリ（shariverse/oshikatsu-countdown-ios・shilokuma-inc/otanecho-ios）は、このままでは入れ替えられない（2026-11-24 の全アプリの配信ビルドの点検）。
設定の形・入力・Secrets の名前は変えないので、minor の版にする。

### 分かっていること

2026-11-24 に、app-kit v1.4.0（b2982f0）・oshikatsu-countdown-ios・kawarin-apple を読み、手元の Xcode 26.6 で小さなアプリ（iOS のアプリと、App Groups を持つウィジェット）を作って確かめた。

| 見たもの | 分かったこと |
| --- | --- |
| v1.4.0 の作り | `embed` は Archive の `ApplicationPath` の `.app` 1 つだけを署名する。ビルドの設定は `-scheme` の `-showBuildSettings` から、製品の名前で本体を選ぶ。`check` は `Payload/*.app` の 1 つ（pkg も入れ子を除いた `.app`）しか見ない。確かめは「Archive の署名」と「書き出したもの」を比べるだけなので、`embed` が入れ損ねる（拡張を飛ばした・`CODE_SIGN_ENTITLEMENTS` が空に解決された）と、両方に無いので通る |
| 署名なしの Archive（iOS・visionOS） | 本体も `PlugIns/*.appex` も署名が無い（`code object is not signed at all`）。Export は各バンドルの署名の entitlement だけを引き継ぐので、拡張も Archive の後に署名しておかないと抜ける |
| 署名の順 | 内側（拡張）を先に、外側（本体）を後に署名すると、`codesign --verify --deep --strict` が通る。外側を先にすると、内側を署名した時点で外側の封が壊れる（`a sealed resource is missing or invalid`） |
| ビルドの設定 | `-showBuildSettings -scheme` には、依存先の拡張のターゲットが出ない。`-alltargets` には出る（先頭のターゲットを 2 回出す）。`-alltargets` は `-derivedDataPath` と一緒に使えない |
| 名前の重なり | kawarin は、iOS のターゲット `Kawarin` と macOS のターゲット `KawarinMac` が、同じ `Kawarin.app`・同じ Bundle ID を作る。`-sdk` を付けると、どのターゲットもそのプラットフォームの値になる（`SUPPORTED_PLATFORMS` も）。`-sdk` を付けなければ、ターゲットごとのプラットフォームが出る |
| 手本 | oshikatsu の `.github/scripts/embed-entitlements.rb`（`-alltargets`・`FULL_PRODUCT_NAME` で突き合わせ・内側から署名）と、`_archive.yml` の全バンドルの確かめ。develop（run 45182829544）・release/1.2.0（run 44670515560）とも、本体とウィジェットに App Groups が入っている |
| macOS で profile の要る entitlement | kawarin は、本体の `com.apple.developer.system-extension.install` などのため、macOS を API キーの自動の署名で Archive している（アドホック署名では `requires a provisioning profile` で止まる、と kawarin の `_archive.yml` にある）。camera extension の entitlements は sandbox と App Groups（`$(TeamIdentifierPrefix)…`）だけ |

### 決めたこと

2026-11-24 にユーザーが決めた。

| 決めたこと | 決定 | 採らなかった案 |
| --- | --- | --- |
| 対象のバンドル | Archive の `.app` の中の、`.app`・`.appex`・`.systemextension`・`.xpc` のバンドルをすべて扱う（`.framework` の中は除く）。watchOS のアプリ（Archive したプラットフォームと違うバンドル）は、見つけたら理由を出して止める | watchOS も `-sdk watchos` の設定を別に読んで扱う／`.appex` だけを扱う |
| 記録 | バンドルごとの entitlements を、artifact `entitlements-<プラットフォーム>`（JSON。IPA・pkg は上げない）と Job Summary に出す | Job Summary とログだけ |
| macOS で profile の要る entitlement を持つ拡張（kawarin） | v1.5.0 では扱わない。macOS の拡張は Xcode のアドホック署名のまま（足さない）にし、確かめだけを全バンドルに広げる。kawarin は今のワークフローのまま | 拡張にも自動の署名で読んだ項目を足す（アプリ側の xcconfig で自動の署名のときだけ付ける形）／`.github/app-kit.json` に macOS の Archive を自動の署名にする入力を足す（Archive にも鍵が要り、self-test で流せない） |
| app-kit の確かめ | `fixtures/ExtensionApp`（XcodeGen。iOS のアプリと、App Groups を持つウィジェット）を足し、self-test で Archive（書き出しの手前まで）を流す。macOS は `fixtures/MacApp` にウィジェットを足す。どちらも artifact の記録で、拡張に App Groups が入ったことを確かめる | 今の `fixtures/App` にウィジェットを足す（Xcode で作った pbxproj を手で直す）／iOS だけ足す |

この設計で決めた既定（承認のときに一緒に確かめた）:

- ターゲットとの突き合わせ
  - 本体は今と同じく、`-scheme` の設定から製品の名前で選ぶ
  - 中のバンドルがあるときだけ、`-alltargets -sdk <SDK>` を 1 回読む。`FULL_PRODUCT_NAME` が同じターゲットを選ぶ（同じ名前のターゲットは 1 つにまとめる）
  - Archive のバンドルの `CFBundleIdentifier` と `PRODUCT_BUNDLE_IDENTIFIER` が合うものに絞る（候補が 1 つでも確かめる。別のターゲットの entitlements で署名しないように。Info.plist に `CFBundleIdentifier` が無いバンドルは確かめられないので、製品の名前だけで選ぶ。配信するバンドルは普通持つ）。まだ 2 つ以上なら、`-sdk` なしの設定の `SUPPORTED_PLATFORMS` で、Archive したプラットフォームのターゲットに絞る
  - 見つからない・1 つに決まらないときは、候補を出して止める（黙って飛ばさない）
- 署名の順: 深い（内側の）バンドルから署名する。あるバンドルを署名し直したら、それを入れている外側のバンドルも、足すものが無くても署名し直して封をし直す
  - iOS・visionOS（署名なしの Archive）: 各バンドルを、`CODE_SIGN_ENTITLEMENTS` の `$(…)` を展開したファイルでアドホック署名する。どのバンドルにも entitlements が無ければ、今と同じく何も署名しない
  - macOS（アドホック署名の Archive）: 本体は今と同じく、署名の entitlement に、プロジェクトの既定の署名（自動）で読んだファイルの項目を足す。中のバンドルには足さない。自動の署名で読んだファイルに、中のバンドルの署名に無い項目があれば、配信ビルドから抜けるので止める
- 確かめ
  - `embed` は、バンドルごとに、ソースの entitlements（`CODE_SIGN_ENTITLEMENTS` を展開したもの）と署名の結果を記録（JSON）に書く
  - `check` は、Archive のすべてのバンドルについて、書き出した IPA・pkg の同じ場所のバンドルを探し、Archive の署名のキーと、記録のソースのキーが、すべてあるかを見る。バンドルが無い・キーが無い・`$(…)` が残っていれば止める（値は今と同じく見ない。Export が `aps-environment` などを書き換えるため）
  - 記録の artifact の名前は、`working-directory` が `.` 以外なら、その道を `-` でつないで後ろに付ける（self-test は 1 回の実行で fixture ごとに呼ぶため）
- スタブのフレームワークの署名の直しは、拡張の中の `Frameworks/` にも広げる
- 版は v1.5.0（minor）。入力・Secrets・設定の形は変えない。ただし、中のバンドルにターゲットが見つからないアプリと、watchOS のアプリを含むアプリは、今まで通っていた Archive が止まるようになる（今の約 30 件には無い）
- 初めての入れ替えで外すファイル（`manifest.json` の `replaces`）に、oshikatsu の `.github/scripts/embed-entitlements.rb` を足す

### 確かめ方

- 単体テスト: 入れ子のバンドルの署名の順・外側の署名し直し・名前の重なり・watchOS で止まること・macOS の拡張に足りない項目で止まること・拡張だけ抜けた IPA で止まること
- self-test: 上の「app-kit の確かめ」
- 本物: oshikatsu の一時ブランチで、新しい版の `archive.yml`（Upload しない）を流し、書き出した IPA の本体とウィジェットに App Groups があることを確かめる。拡張の無い shinkeisuijaku-app-ios でも今まで通り通るかを確かめる

### 入れ替えるときに要ること

| リポジトリ | 要ること |
| --- | --- |
| oshikatsu-countdown-ios | v1.5.0 以上で入れ替える（v1.4.0 ではウィジェットの App Groups が抜ける）。`embed-entitlements.rb` は `replaces` で外れる |
| otanecho-ios | v1.5.0 以上で入れ替えれば、本体・ウィジェット・共有拡張の 3 つに App Groups が入る見込み（別のセッションが、今のワークフローのまま直している） |
| kawarin-apple | v1.5.0 では入れ替えない（今のワークフローのまま）。profile の要る項目は本体の `com.apple.developer.system-extension.install` だけで、本体には v1.4.0 から自動の署名のときだけの項目を足せるので、本体の entitlements のファイルを分ければ通る見込みはある（camera extension の sandbox・App Groups がアドホック署名で通るかは確かめていない） |

## Xcode 27（v1.8.0）

app-kit の v1.8.0 で、Build・Archive・Upload の既定の Xcode を 26.6 から 27.1 に上げる（#1293・app-kit#29）。
App Store Connect への Upload で altool が警告 90725 を出している（iOS 26.5 の SDK でのビルド。2027 年 4 月からは iOS 27 の SDK でないと上げられない。2026-11-24 に shilokuma-inc/ninjacord-ios の Upload で確認）。

### 分かっていること

2026-11-24 に、GitHub の runner-images（git の clone）と changelog、対象のリポジトリ（約 30 本。git の浅い clone）を読んだ。

| 見たもの | 分かったこと |
| --- | --- |
| ランナー | `macos-26`（= `macos-latest`）には Xcode 26.0.1〜26.6 しか無い。Xcode 27 は別のラベル `xcode-27`（arm64・macOS 27.0.1）にだけある（2026-07-16 に preview、2026-10-15 に GA）。GitHub は macOS の画像を、OS の版ごとから Xcode の major ごとに変えた（1 つの画像に major は 1 つ） |
| `xcode-27` の中身（20261104） | Xcode 27.0・27.1（既定）・27.2。Simulator は iOS 27.0（iPhone 17・17e・18 Pro・18 Pro Max・Air・iPad）、iOS 27.1（iPhone Duo だけ）、iOS 27.2。iPhone 17 Pro と iOS 26.x のランタイムは無い |
| Deployment Target | Xcode 27.1 の SDK の下限は iOS 15.0・macOS 12.0・visionOS 1.0。対象で一番低いもの（iOS 15.0・macOS 13.0・visionOS 1.0）も範囲の中なので、変えなくてよい |
| Swift | 6.3.3（Xcode 26.6）→ 6.4（Xcode 27.1）。テンプレート由来のリポジトリで、`Shape` への準拠が `#ConformanceIsolation` で落ちる例が 7 本あった（型に `nonisolated` を付けて直る。26.6 でも通る）。ほかには新しいエラーは見つかっていない |
| 今の各リポジトリ | app-kit を呼ぶ 4 本は既定の 26.6。自前の `_build.yml`・`_archive.yml` は `default: '26.6'`（mullion だけ 26.3）、古い 3 本立ては 26.6 の直書きか `latest-stable`。どれもランナーは `macos-latest` |

### この版で決めた既定

- 既定を 27.1 にする（ワーカーと司令塔と同じ版。`xcode-27` の画像の既定）
- ランナーは Xcode の major で決める（27 → `xcode-27`、26 → `macos-26`）。`macos-latest` は行き先が変わるので使わない。`xcodeVersion` に 26.x を書けば、今までどおり `macos-26` の 26.x で流れる（27.1 で落ちるリポジトリの、直すまでの逃げ道）
- Build に、設定を読んでランナーを決める ubuntu のジョブ `plan` を足す（ジョブの `runs-on` は始まる前に決まるため）。必須のチェック `build / build` の名前は変えない。plan が落ちたら `build / build` も落とす（skipped は必須のチェックで通った扱いになるため）
- テストの Simulator は、選んだ Xcode の SDK と同じか古いランタイムから選び、iPhone Duo（縦横比 1398x2034）を除く
- 撮影（`AppStore/screenshots.json`）とクリエイティブアセットは変えない。撮影を 27 にすると iOS 27 の見た目になり、機種の名前も変わる（6.9 inch は iPhone 18 Pro Max など）ので、別に決める
- 版は minor（入力・Secrets・設定の形は変えない）。v1.7.0（撮影の assetsFrom・スタブの署名の直し。app-kit#28）とは分け、戻すときに Xcode の直しだけを外せるようにする

### 各リポジトリへの届け方

| 形 | 届け方 |
| --- | --- |
| app-kit を呼ぶ（askhub-create-check・shinkeisuijaku・2 つのテンプレート） | v1.8.0 を「広げる」。落ちたリポジトリは直してから「もう一度試す」（直すまでは `xcodeVersion` に 26.6） |
| まだ自前のワークフロー | 入れ替え（「準備をやり直す」）で既定が 27.1 になる。入れ替えに使う版（状態の `app-kit.json` の `adoption`）を v1.8.0 以上にしてから行う。2027-03 までに入れ替えが済まないリポジトリだけ、`_build.yml`・`_archive.yml` の Xcode とランナーを直す（`.github/workflows/` はワーカーのトークンでは直せないので、司令塔の管理用のトークンか人のセッション） |
| このリポジトリ | 入れ替えは最後なので、自前の `_build.yml`・`_archive.yml` を 27.1・`xcode-27` にした（#1293）。撮影は 26.6 のまま |

## 決めずに残すこと

- XcodeGen への移行（段階 5 の 7）。app-kit は `generate` で XcodeGen のリポジトリも扱えるようにしておき、テンプレートを XcodeGen にするかは段階 5 の 7 で決める
- 複数のアプリで同じ Swift のコードを持つようになったときの Swift Package（上の「置かないもの」）
- クリエイティブ素材のワークフロー。司令塔でプロダクトページのヘッダー・検索結果の素材を作れるようになったら、各リポジトリから外す（[release.md](release.md) の「プロダクトページのヘッダーと検索結果の素材」）。作り方の設計は [creative-assets.md](creative-assets.md)（#1235）
- Upload の鍵を Environment の Secrets に移すこと（#1067）。移すときは、app-kit の `app-archive.yml` の `environment` と、呼ぶ側の Secrets の渡し方を一緒に変える（major を上げる）
- macOS のスクショ（上の「macOS のアプリ」）。このリポジトリを入れ替えるときに、今の方式を app-kit に取り込むかを決める
- iOS と macOS の両方でテストを流すこと（今の Build は `platforms` の先頭だけテストし、残りはビルドだけ）。このリポジトリを入れ替えるときに決める
- Android のリポジトリ（段階 6）。同じ形（再利用ワークフロー・写すファイル・版を広げる）で、別の再利用ワークフローを足す見込み
