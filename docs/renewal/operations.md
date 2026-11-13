# 運用

## 通知

- 人の出番は、常時オンの Mac の司令塔から APNs で iPhone と Mac に直接送る。外部の通知サービスは使わない
  - iOS のローカル通知は、アプリが裏で動ける時間を OS が決めるので遅れる
  - GitHub の通知は、自分の書き込みを自分に知らせないので使えない（人も機械も同じアカウント）
- APNs の鍵は Keychain に置く（[security.md](security.md)）。端末の宛先は、クライアントが状態リポジトリに書く
- 進行を止めるものは、司令塔が 1 周（30 秒）ごとに状態リポジトリから拾い、まだ知らせていなければすぐ送る（`AskHubCommander` の `Notifier`）
  - 要回答: 質問が回答を待っている（`questions.json` の `open`）。着手前の確認の分け方の判断（epic が `awaitingSplit`）と、ゴールの確認と開始（`awaitingStart`）も、人が返事をするまで進まないので含める
    - 最終 PR の確認とマージの承認（epic が `reviewing`）も、人が判断のカードに答えて承認するまで最終 PR が止まるので含める。最後のレビューの後に直し・マージが動いていないときだけ（承認してマージが動き出したら、もう待っていない）。答えていない判断のカードの数を文に出す
  - 自動の対処の使い切り: ジョブが人の判断を待っている（`waitingHuman`。直させる回数を使い切ったときと、認証切れ・想定外ですぐ人に渡したとき）
  - ワーカーがオフライン: ジョブ（`assigned`・`running`・`paused`）を持った Mac の生きている印が 1 時間より古いとき。ジョブを持っていない Mac は、どれだけ戻らなくても知らせない
  - GitHub の残りが少ない: 司令塔が読んだ REST の上限の残りが 1,000 回を切ったとき（下の「GitHub の上限」）。使い切ると司令塔もクライアントも戻るまで止まるので、その前に知らせる
  - リジェクトは、審査の状態を状態リポジトリに持つ段階 5 で足す
- 同じ出来事は二度送らない。知らせた出来事を `notifications.json` に記録し（[protocol.md](protocol.md)）、記録を書けたときだけ送る
  - 見直して版が変わった質問・説明ができた質問・直したゴール・次の試行で人に渡したジョブ・一度戻ってからまた止まった Mac・次の窓（1 時間）でまた少なくなった GitHub の残りは、別の出来事として知らせ直す
  - 最終 PR の確認の待ちは、最後のレビュー（見た head）ごとに別の出来事にする。人が頼んだ直し（判断のカードの「別案にする」「直してほしい」・最終 PR への指示）の後にもう一度 `reviewing` になれば、直した head の確認の待ちとして知らせ直す。直しで head が変わらなくても、直させたカードは答え待ちに戻るので知らせ直す
  - 1 つの epic（Mac）について同じ周に見つけた出来事は、1 通にまとめる（質問が 5 件出ても 1 通）
  - どの端末にも届かず、送り直せる失敗（APNs の障害・上限・つながらない・鍵や設定の誤り）だったときは、記録から外し、1・2・5・10・30 分と待ちを延ばして送り直す。宛先が使えないだけ（アプリを消した・古い宛先）なら送り直さない
  - APNs が `400 BadDeviceToken`（トークンが送り先の環境のものでない）で断ったときは、もう一方の環境（production と development）にその場で 1 回だけ送る。環境を取り違えて登録した古い版のアプリでも届くようにするため。届いたら司令塔のログに、宛先の環境が違うことを出す
  - 送る途中で司令塔が落ちたときは送り直さない（二重より取りこぼしを選ぶ。記録してから送り終えるまでの数秒の間だけ）
  - 終わった出来事の記録は、7 日たってから消す（GitHub の障害で一覧が空に見えた周に、記録を消して知らせ直さないため）
- 送る宛先は、`devices/` のうち、確かめた公開鍵の一覧にある（登録済みで取り消していない）端末だけ。なくした端末の鍵を取り消せば、その端末には送らない
- クライアント（iOS・macOS）は、状態リポジトリにつながってこの端末の鍵が登録された後に、一度だけ通知の許可を求める（`AskHub/Push/PushRegistration.swift`）
  - 鍵の登録は、起動のときと、設定を開いたとき（「登録を確かめ直す」を含む）に確かめる。登録の前に許可を求めないのは、登録されていない端末には司令塔が送らないため
  - 許可されていれば、起動のたびに APNs に登録し、届いたデバイストークンを `devices/<この端末の鍵の id>.json` に書く。トークン・APNs の環境・端末の種類が同じなら書かない（変わったら書き直す）
  - APNs の環境は、ビルドの構成（Debug・Release）ではなく署名から決める（`PushRegistration.environment`）。APNs は署名の entitlement の環境のトークンを返し、Xcode の自動の署名はその値を provisioning profile に合わせるので、開発用の署名で作った Release の版も `development` になる
    - iOS の実機は、埋め込みの profile（`embedded.mobileprovision`）の `aps-environment`。profile の無い版（App Store・TestFlight。Apple が profile を外して配る）は `production`（`AskHubClient/APNsProvisioning`）
    - iOS の Simulator は `development`。macOS は、自分の署名の entitlement（`com.apple.developer.aps-environment`）を読む
    - ビルド設定 `APS_ENVIRONMENT`（`Configs/Debug.xcconfig` は `development`、`Release.xcconfig` は `production`）は entitlement のファイルに入れる値で、署名の値とは限らない。前は Info.plist に入れて書いていたので、開発用の署名の Release の版が development のトークンを `production` と書き、通知が BadDeviceToken で断られた（#1059）
    - Xcode から入れた版と TestFlight の版はトークンが違う。入れ替えたら一度アプリを開くと、新しいトークンと環境に書き直す（開くまでは前の版のトークンのままで届かない）
  - 断られたら、設定の「通知」に、通知が届かないことと、設定アプリ（Mac はシステム設定）の通知の画面を開くボタンを出す
  - デモのデータ（UI テスト・撮影を含む）と、アプリの中で動く単体テストでは、許可を求めず宛先も書かない
  - macOS の push の entitlement は provisioning profile が要り、profile の無いアドホック署名ではビルドが止まる。アドホック署名（CI・ワーカー・スクショ・archive。`CODE_SIGN_STYLE=Manual`）では付けず、自動の署名のときだけ付ける（`Configs/Project.xcconfig` の `ASKHUB_MACOS_ENTITLEMENTS_*`）。アドホック署名の Mac のアプリは通知を受け取れない
  - 配布（TestFlight・App Store）の archive は、iOS は署名せずに、macOS はアドホック署名で作るので、`Tools/embed_archive_entitlements.py embed` で push の entitlement をアドホック署名で埋め込んでから Export する（`_archive.yml`。macOS は sandbox などに足して署名し直す）。
    Export は archive の署名の entitlement だけを引き継ぐので、埋め込まないと TestFlight の版に push の entitlement が入らず、APNs への登録が失敗する。
    Export の後に IPA・pkg に残ったかを確かめ（`check`）、落ちていれば App Store Connect に上げずに止める
  - Mac には、TestFlight の版をデバイス登録なしで入れられる（[docs/release.md](../release.md) の「Mac に TestFlight の版を入れる」）
- 入れ方: Apple Developer の Identifiers で App ID（`jp.shilokuma.AskHub`）の Push Notifications を有効にする（push の entitlement を付けたので、無効のままだと実機と Mac の自動の署名の profile に入らない。TestFlight の版も配布用の profile に入らず、Upload が Export か IPA の確認で止まる）。
  Keys で APNs の鍵を作って .p8 を落とし、常時オンの Mac の端末で `askhub-commander apns --key-id <鍵の id> --team-id <Team ID> --key-file <.p8 のパス>` を流してから、常駐を読み込み直す（`launchctl kickstart -k gui/$(id -u)/jp.shilokuma.askhub.commander`）
  - .p8 の中身は Keychain（`apns-key`）にだけ置き、設定には鍵の id・Team ID・Bundle ID（既定 `jp.shilokuma.AskHub`。iOS と macOS で同じ）だけを書く。.p8 は Apple Developer から一度しか落とせないので、Mac には残さず安全な場所に移す
  - APNs の設定が無ければ通知を送らない（起動のログに出る）。`askhub-commander check` で鍵の様子（値は出さない）を確かめる
- 通知の中身の `askhub`（`repo`・`epic`・`mac`）は、クライアントが通知から開く先。epic は「進行中」のその epic の画面、Mac は「Mac」のその Mac の画面を開く（`AskHub/Model/PushTarget.swift`）。形の違う値では開かない
  - アプリを開いている間に届いた通知も、バナーで出す
- 頻度

  | 種類 | 例 | 知らせ方 |
  | --- | --- | --- |
  | 進行を止めるもの | 要回答（最終 PR の確認とマージの承認を含む）・自動の対処の使い切り・ワーカーがオフライン・リジェクト | すぐ |
  | 止めないもの | 実機確認（段階 4 の 2 で作る） | まとめて 1 日に数回 |

- 「ワーカーがオフライン」は、そのワーカーがジョブを持っていて、一定の時間戻らないときだけ知らせる（MacBook を閉じるたびに知らせない）
- 司令塔そのものが止まったときは、GitHub Actions の見張りが Issue を立て、GitHub の通知で知らせる（下の「司令塔の見張り」）
- Android の通知は、Android のクライアントを作るときに決める（実用上 FCM がほぼ必須。端末の宛先の形は、FCM の宛先も入るようにしておく）

## 司令塔の見張り

司令塔が止まると APNs の通知も止まるので、状態リポジトリの GitHub Actions の定期実行（`Commander/Watch`）が、司令塔の生きている印（`commander.json` の `seenAt`）を確かめる（[architecture.md](architecture.md) の「見張り」）。

- 止まったとみなすのは、`seenAt` が 30 分（`JobTiming.macStaleAfter` と同じ。司令塔は 10 分ごとに書く）より古い・`commander.json` が無い・読めない（AskHubKit の `StateFileCoder` と同じ読み方）・5 分より先の時刻（Mac の時計が進んでいると、止まっても古さで気づけない）とき
- 止まったら、github-actions[bot] が状態リポジトリに Issue を立てる。bot の書き込みなので、状態リポジトリを Watch している人に GitHub の通知が届く
  - GitHub Mobile は、Watch しているリポジトリの出来事をアプリの通知の一覧に出すだけで、プッシュでは知らせない（プッシュの対象は、メンション・割り当て・レビューの依頼・デプロイの承認の依頼）。iPhone に届けるため、状態リポジトリの変数 `COMMANDER_WATCH_ASSIGNEES`（カンマ区切りの GitHub のアカウント）の人に Issue を割り当てる。空なら割り当てない。割り当てられない人（リポジトリを見られない など）は GitHub が黙って外すので、Job Summary に出す
  - まだ戻っていない見張りの Issue があれば、開いていても人が閉じていても重ねて立てない（戻るまでの間に、1 時間ごとに立て直さない）
  - 戻ったら（30 分以内の `seenAt` を見たら）、まだ戻っていない見張りの Issue にコメントし、開いていれば閉じる
  - 見張りの Issue は、author が github-actions[bot] で、本文の最後の行が目印（`<!-- askhub-commander-watch v1 down -->`。戻ったら `recovered` に書き換える）のものだけ。private でも目印だけで見分けない（LEARNINGS.md）
- 間隔は 1 時間ごと（毎時 23 分）。private のリポジトリの Actions の分は、1 回のジョブごとに 1 分に切り上げて数えられ、Free の organization の枠は月 2,000 分。1 時間ごとで月 720 分（36%）、30 分ごとだと月 1,440 分（72%）になり、ほかの private のリポジトリ（2026-10 は月 200 分ほど）の枠を圧迫する。止まってから気づくまでは、30 分（古さ）+ 最大 1 時間（間隔）+ 定期実行の遅れ（GitHub の混み具合で数分〜数十分）
- 使う権限は `GITHUB_TOKEN`（contents: read・issues: write）だけで、ほかの秘密は足さない
- 見張りの run そのものが失敗したとき（GitHub を読めない・書けない。読み取りは 3 回まで試す）は run が失敗になり、GitHub が、ワークフローの cron を最後に書き換えた人（入れた人）にメールで知らせる
- GitHub の障害で Issue の一覧が空で返ると、重ねて立てることがある（LEARNINGS.md の 2026-10-22 の障害）。戻ったときにまとめて閉じる

### 正本と入れ方

- 正本は ask-hub-apple の `Tools/askhub-state/commander-watch.yml`（ワークフローの雛形）と `Tools/commander_watch.py`（判定と Issue の操作。テストは `Tools/tests/test_commander_watch.py`。PR では Verify/App Store metadata が流す）
- 状態リポジトリには、ワークフローのファイル 1 つ（`.github/workflows/commander-watch.yml`）だけを入れる。ワークフローは、判定を ask-hub-apple の固定したコミットから取り出して動かす（public なので秘密は要らない）
  - 判定を状態リポジトリに置かないのは、`.github/workflows/` の外のファイルは司令塔のトークン（Contents の書き込み）でも書き換えられるため。`.github/workflows/` のファイルを変えるには Workflows の権限が要るので、司令塔のトークンには Workflows の権限を付けない
- 入れ方（人が手元の Mac で）:
  1. 状態リポジトリを Watch しているか確かめる（Watch → All Activity か、Custom の Issues）。通知は Watch している人にだけ届く
     - iPhone にプッシュで届けるなら、割り当てる人を変数に入れ（`gh variable set COMMANDER_WATCH_ASSIGNEES -R shilokuma-inc/askhub-state -b <アカウント>`）、GitHub Mobile の設定 → 通知で割り当て（Assigned）のプッシュをオンにする
  2. 司令塔を先に入れ、`commander.json` ができたのを確かめる（先に見張りを入れると、印が無いので Issue が立つ。司令塔が書けば閉じる）
  3. ワークフローを書き出す。判定の版には、リモートのブランチに入ったコミットを使う（`render-workflow` が確かめ、SHA に直して書く）

     ```bash
     git -C <ask-hub-apple> fetch origin
     python3 <ask-hub-apple>/Tools/commander_watch.py render-workflow --ref origin/renewal --output <askhub-state>/.github/workflows/commander-watch.yml
     ```

  4. 状態リポジトリの main に commit して push する。`.github/workflows/` を変えるので、gh のトークンに `workflow` の scope が要る。司令塔の書き込みと重なって断られたら、pull してやり直す
  5. Issue を立てずに判定だけを流し、Job Summary を見る

     ```bash
     gh workflow run commander-watch.yml -R shilokuma-inc/askhub-state -f dry-run=true
     ```

- 手元で判定だけを確かめる（gh のログインで読むだけ。Issue は触らない）: `python3 Tools/commander_watch.py check --repo shilokuma-inc/askhub-state --dry-run`
- 更新: 正本を直して `renewal`（切り替えの後は develop）に入れたら、入れ方の 3〜5 をやり直す（判定の版が新しいコミットに変わる）
- 止め方: 司令塔を長く止めるとき（Mac の入れ替えなど）は `gh workflow disable commander-watch.yml -R shilokuma-inc/askhub-state` で止め、戻したら `enable` する

## Mac の一時停止・再開・引き継ぎ

- Mac を閉じたり、ネットワークから外れたりしたら、その Mac のジョブを一時停止する。同じ Mac がオンラインに戻ったら、続きから再開する（自動。人の操作は要らない）
- ほかの Mac への引き継ぎは、人がクライアントで選ぶ（自動では移さない）。引き継ぎ先は、どの Mac でもよい
- 引き継ぐときは、最後に push したところから続ける（タスクの区切りごとに作業ブランチを push しておく）
- 常駐できない Mac では、ワーカーをターミナルのコマンドで起動する。止まるのは再起動とログアウトのときで、クライアントに「オフライン」と出るので、もう一度起動すれば続きから再開する

### 人の操作

クライアントの epic の画面の「操作」から送る（開始した後だけ出る）。非常口では `askhub pause`・`askhub resume`・`askhub handover --mac <Mac の名前>`（どれも `--repo`・`--epic` を付ける。`askhub status` に一時停止中かが出る）。

| 操作 | すること | 送れるとき |
| --- | --- | --- |
| 一時停止 | 動いているジョブは最後まで終わらせ、まだ動いていないジョブを止め、次のジョブを作らない。epic の画面の「いま」と、「進行中」の「一時停止中」の区分に出る | 開始した後（実装・最終 PR の段取り・人の確認の待ち） |
| 再開 | 一時停止で止めたジョブを戻し、次のジョブを作るのを再開する。Mac がオフラインで止まったジョブは、その Mac が戻るのを待つ | 一時停止しているとき |
| ほかの Mac に引き継ぐ | epic の Mac を移す先に替え、動いていないジョブを移す先に付け替える。移す先は、作業ブランチ（最後に push したところ）から作業場所を取り出す | 一時停止中か、epic の Mac で動いているジョブが無いとき |

- 一時停止の間も、判断のカードへの答え・マージの承認・やり直すは受け付ける。作られたジョブは止めたままにし、再開してから動かす
- Mac を閉じて戻せないときは、「ほかの Mac に引き継ぐ」で移す先を選ぶ。Mac がオフラインならジョブは止まっているので、そのまま送れる。オフラインになって間もない（Mac の生きている印が 30 分古くなるまでの）間は、ジョブがまだ動いていることになっていて断られるので、先に一時停止する
- 移す先はオフラインでもよい。その Mac のワーカーが動き出したら続きから動く（クライアントは「オフライン。戻ると続きから動きます」と出す）。ジョブを受けない Mac（自己診断に問題がある・ワーカーが動いていない）は選べない
- 前の Mac で push していない変更は捨てる。前の Mac は、戻っても epic の Mac でないので、その epic のジョブを新しく引き受けない（眠っていた試行が戻って結果を書いたときは、どの試行でも成功が書かれたらジョブを成功にする決まりで扱う。[protocol.md](protocol.md) の「ジョブの引き受けと試行の段取り」）
- 実装の会話は、それを動かした Mac にだけ残る。移す先では、タスクの直し（`fixTask`）を新しい会話で（ゴールとタスクを渡して）続ける。実装の途中の質問の答えで再開するジョブも、移す先では作業場所を取り出し直して新しい会話で続ける
- 前の Mac に残った作業場所と DerivedData は、epic が終わった後に、その Mac の定期の見回りで消す（下の「容量」）

## ワーカーと司令塔の配り方

- 常時オンの Mac で Developer ID で署名し、Hardened Runtime を付けたものを配る（下の「署名と公証」）。自分の Mac には手元から ssh で入れ替え、共同開発者には GitHub Releases で配る（下の「ワーカーの更新」「GitHub Releases」）
- 入れ方は、プログラムのファイルをホームフォルダの下（`~/Library/Application Support/AskHub/bin/`）に置き、`setup` で値を登録するだけ。管理者の権限は使わない
- 常駐できる Mac では、ログイン中のセッションの LaunchAgent として登録する（ssh のセッションからは Keychain を読めないため）。常駐できない Mac では、ターミナルで `askhub-worker run` を流したままにする（下の「ワーカーの入れ方」）
- `claude` は 1 か所にだけ入れ、版を固定する。段階 0 で、常時オンの Mac に 2 か所・別の版で入っていたことが分かった
  - 司令塔とワーカーは、設定の `claude`（`setup --claude` で渡した絶対パス）だけを使い、`DISABLE_AUTOUPDATER=1` を渡して自分で更新させない
  - 生きている印を書くたび（10 分ごと）に `claude --version` を測り直して `versions.claude` に書く。人が入れ替えたら、読み込み直さなくても次の印で分かる
  - クライアントは、Claude Code の版が司令塔と違う Mac を、Mac の画面と「あなたの番」（時間のあるときに）に出す。オフラインの Mac は、戻ってから出す
  - 版をそろえるには、司令塔と同じ版の `claude` を、その Mac の設定の `claude` の場所に入れる（次の Claude の呼び出しから使う）
- ビルドとテストに使う Xcode は、Mac の `xcode-select` に任せず、設定の `xcode`（`Xcode.app` か、その下の `Contents/Developer` の絶対パス）で決める
  - `askhub-commander xcode <Xcode.app のパス>`（ワーカーは `askhub-worker xcode`）で決める。決める前に、その Xcode の `xcodebuild -version` を読めることを確かめる（ライセンスに同意していない Xcode は断る）。`xcode --unset` で xcode-select で選んだものに戻す。`setup` を流し直しても残る
  - 司令塔とワーカーは、ビルド・テスト・Simulator の操作・スクショの子に `DEVELOPER_DIR` でその Xcode を渡す。人が `xcode-select` を切り替えても、ワーカーのビルドとテストは同じ Xcode で流れる（2026-11-10 に常時オンの Mac の `xcode-select` が Xcode 26.6 に切り替わり、iOS 27.0 の Simulator を使うジョブが 2 回続けて止まった）。決めていなければ今までどおり `xcode-select` で選んだもの
  - 決めた Xcode を消した・名前を変えたときは、ビルドと Simulator の用意の前に理由の分かる文で止める（環境の不調として人に渡る）。起動のログ・`check`・アプリの Mac の詳細（「Xcode」の行）で、どの Xcode を使っているかが分かる
  - 生きている印を書くたび（10 分ごと）に `xcodebuild -version` を測り直して `versions.xcode` に書く。決めていない Mac で xcode-select を切り替えたら、次の印で分かる
  - 決めた値は常駐が起動したときに読むので、決め直したら読み込み直す（`launchctl kickstart -k gui/$(id -u)/jp.shilokuma.askhub.<役割>`。ターミナルで `askhub-worker run` を流している Mac は流し直す）
- 生きている印に版と互換の番号を書く。互換の番号が司令塔と合わないワーカーは、ジョブを引き受けずに知らせる（下の「版」）
- 更新は、常時オンの Mac と ssh で届く自分の Mac は手元から遠隔で、共同開発者の Mac はその人が手で行う（下の「司令塔の更新」「ワーカーの更新」「共同開発者の Mac」）
- 作業ファイルは TCC の保護の対象の場所（デスクトップ・書類など）に置かない。ワーカー専用のフォルダを使う
  - 設定と Claude のフォルダは `~/Library/Application Support/AskHub/<役割>/`
  - 対象のリポジトリの写し・epic の作業場所・DerivedData・ビルドの一時フォルダは、パスに空白の無い `~/Library/Developer/AskHub/<役割>/`（`work`・`builds`・`builds-tmp`）。パスの空白を扱えないビルドのプラグインやスクリプトがあるため（2026-11-09、prime-pick-ios の LicenseList のプラグインが `SourcePackages not found` で止まった）
  - 移す前の版で作った `~/Library/Application Support/AskHub/<役割>/` の `work`・`builds`・`builds-tmp` は、移した後は使わず、epic の片付けでも消えない。動いている epic は、次のジョブで作業ブランチ（リモート）から新しい場所に取り出し直す
  - 前の場所は、動いている epic が無いとき（実装の途中の質問を待っている epic も無いとき）に手で消す。消すのは `work`・`builds`・`builds-tmp` の 3 つだけで、同じフォルダの `config.json` と `claude/` は今も使うので残す
    - 消す前に、epic の作業場所（`work/epics/<epic>/repository/<リポジトリ名>`。`work/epics/<epic>/` は git の作業場所ではない）に、push していない変更や stash が残っていないかを `git -C <作業場所> status`・`git -C <作業場所> log HEAD --not --remotes`・`git -C <作業場所> stash list` で確かめる。epic の作業ブランチには upstream が無いので、`git log @{u}..` は使えない
    - 残っていれば作業ブランチに push してから消す。ただし、場所を移す前に止まった試行の、コミットしていない変更が残っていることがある。新しい場所でやり直したタスクのコミットと見比べて、中身が入っていれば push は要らない（2026-11-09、prime-pick-ios）
    - 消すのはゴミ箱に入れる（取り消せるように）。ssh 越しでは Finder を使えないので、`~/.Trash/<名前>/` に `mv` する（Finder の「戻す」は使えないので、戻すときも `mv`）。ゴミ箱に入れただけでは空き容量は増えず、ゴミ箱を空にしたとき（Finder の「30 日後にゴミ箱から削除」が有効なら 30 日後）に空く

### 署名と公証

司令塔・ワーカー・非常口は、どれも Developer ID Application（チーム `XU74X3434S`）で署名する。同じ識別子とチームで署名し続ければ、Keychain の項目の「常に許可」と TCC の許可が、入れ替えた後も続く（アドホック署名はビルドのたびに別のプログラムとみなされ、確認が項目の数だけ出る。[LEARNINGS.md](../../LEARNINGS.md) の「Keychain」）。実装は、署名と自分の Mac への入れ替えが #1064、公証と GitHub Releases が #1065。

| 実行ファイル | 識別子 | Keychain のサービス |
| --- | --- | --- |
| `askhub-commander` | `jp.shilokuma.askhub.commander` | `jp.shilokuma.AskHub.commander` |
| `askhub-worker` | `jp.shilokuma.askhub.worker` | `jp.shilokuma.AskHub.worker` |
| `askhub`（非常口） | `jp.shilokuma.askhub.cli` | `jp.shilokuma.AskHub.cli` |

- 署名は、常時オンの Mac の常駐（`jp.shilokuma.askhub.deploy`。下の「司令塔の更新」）が行う。署名の鍵は常時オンの Mac のログインキーチェーンにだけ置き、CI（GitHub の Secrets）には置かない
  - public のリポジトリでは、Secrets を読めるワークフローが 1 つでも誘導されると、個人の名前の Developer ID で何にでも署名できるようになる。漏れたら証明書を失効させ、作り直した証明書で署名し直して、すべての Mac に配り直すことになる。今のワークフローは Environment ではなく organization の Secrets（多くは公開範囲がすべてのリポジトリ）を使っていて、[security.md](security.md) の「public のリポジトリと Secrets」の決まりにまだ合っていない（#1067）
  - 司令塔は常時オンの Mac が無いと動かないので、署名をそこに頼っても、止まる理由は増えない
  - タグからの再現できるビルドと公開のログ（build provenance）が要るようになったら、「CI が秘密なしでビルドし、常時オンの Mac が確かめてから署名する」形に移す。鍵は動かさない
- ビルドは、鍵の無い手元の Mac で行う。`origin/develop` に入ったコミット（リリースはタグ）を一時の git worktree に取り出してビルドし、作業中の変更を入れない
  - アーキテクチャは arm64 だけ（macOS 27 は Apple シリコンだけで、今の Mac もすべて Apple シリコン）。Intel の Mac が要るときは `--arch x86_64` を足す
- 署名は `codesign --force --sign <Developer ID Application> --identifier <識別子> --options runtime --timestamp`。entitlement は付けない
  - Hardened Runtime を付けても、今の動き（`Process` での claude・git・xcodebuild・simctl の起動とその孫のプロセス、Keychain の読み書き）は変わらない。JIT・DYLD の環境変数・ほかのチームのライブラリの読み込み・Apple Events を使わないため。リンク先は OS のライブラリ（`/usr/lib`・`/System/Library`）だけなので、ライブラリの検証にも当たらない（2026-11-12 に、アドホック署名に Hardened Runtime を付けて確かめた）
  - 署名の要件（designated requirement）は識別子とチームで決まり、証明書そのものには結びつかない。証明書を作り直しても、Hardened Runtime を後から付けても、同じ識別子とチームなら Keychain の許可は続く
  - 入れる前に、要件で確かめる: `codesign --verify --strict --test-requirement '=anchor apple generic and identifier "jp.shilokuma.askhub.worker" and certificate leaf[subject.OU] = "XU74X3434S"' <ファイル>`。`codesign --verify` は ssh のセッションでも使える（使えないのは署名だけ）
- 公証（notarization）は、GitHub Releases に出す版だけにする
  - Gatekeeper が確かめるのは、隔離の印（`com.apple.quarantine`）が付いたファイルだけ。ブラウザで落としたファイルには付き、`scp`・`gh release download`・`curl` で取ったファイルには付かない（2026-11-12 に確かめた）。ssh で送る自分の Mac の版は、公証しなくても動く
  - 裸の Mach-O は staple できないので、zip（`ditto -c -k --keepParent`）にして `xcrun notarytool submit --wait` に出し、配るのもその zip にする。チケットは Apple のサーバーにあり、ブラウザで落とした zip から出したものは、初めて動かすときに Gatekeeper がネットで確かめる
  - pkg は使わない。Developer ID Installer の証明書が別に要り、入れる先が既定でシステムの場所になり、管理者の権限が要る。dmg は staple できるが、CLI 1 つにマウントの手間が増える
  - 公証の資格は、App Store Connect の Team の API キー（役割 Developer。Apple の文書には無くフォーラムの報告によるので、作るときに `store-credentials` で確かめる）。常時オンの Mac で `xcrun notarytool store-credentials askhub-notary --key <.p8> --key-id <id> --issuer <id>` で Keychain に置き、.p8 は置いた後に消す（APNs の鍵と同じ扱い）

### 版

- 版は実行ファイルに埋め込む（ビルドのときに Info.plist を `__TEXT,__info_plist` に入れる）。`git describe --tags --match 'machine-v*'` から作り、タグそのものなら `0.2.0`、その後のコミットなら `0.2.0-3-gabc1234`。埋め込んでいないビルドは `0.0.0-dev`。`machine-v*` のタグがまだ無いときは `0.0.0-<コミットの数>-g<短いハッシュ>`（タグの後のコミットと同じ形）
  - ビルドは `scripts/machine/build.sh <プロダクト> ...`（`askhub-commander`・`askhub-worker`・`askhub`）。識別子・版・コミットを Info.plist にして埋め込み、`AskHubKit/.build/release/<プロダクト>` に出す。`scripts/commander/deploy.sh` もこれを使う。`swift build` をそのまま流すと埋め込まれない
  - 入れ替えた後は `askhub-worker version`・`askhub-commander version` で、版・コミット・互換の番号を確かめる（Keychain を読まないので、ssh のセッションからも流せる）。非常口（`askhub`）には `version` が無いので、`launchctl plist __TEXT,__info_plist <ファイル>` で読む
- 生きている印（`versions.worker`・`versions.commander`）には版と互換の番号を、`check`・起動のログ・`version` には版・コミット・互換の番号を出す
- 照らし合わせは、版の一致ではなく互換の番号（整数）で行う。共同開発者のワーカーは、司令塔を入れ替えるたびにそろえられないため。互換の番号は `MachineCompatibility.current`（AskHubProtocol）で、生きている印の `versions.compatibility` に書く（[protocol.md](protocol.md) の「macs/<mac>.json」）
  - 互換の番号は、司令塔とワーカーの間の決まり（ジョブの種類・入力と出力・試行の書き方・状態のファイルの形）を変えたときだけ上げる
  - 司令塔と互換の番号が合わないワーカーは、ジョブを引き受けず（持っているジョブは手放さない）、理由を生きている印の `refusal` に書く。クライアントは Mac の画面と「あなたの番」に更新の手順を出す
  - ワーカーは周ごとに `commander.json` を読んで照らし合わせる。番号を書かない前の版の司令塔・`commander.json` が無いときは照らし合わせずに引き受ける。知らない版・形の違う `commander.json` は、司令塔の決まりが変わったとみなして引き受けない。GitHub に届かないなどで読めないときは前の周の判断のまま（起動してから一度も読めていなければ引き受けない）
  - ワーカーのほうが番号が大きいときも引き受けず、クライアントは「司令塔を更新する」と出す。常時オンの Mac のワーカーは司令塔と同じ実行ファイルなので、クライアントでは照らし合わせない
  - 版が違うだけ（互換の番号は同じ）なら、Mac の詳細に出すだけで、更新を急かさない

### GitHub Releases

共同開発者には、ask-hub-apple（public）の GitHub Releases で配る（#1065）。実行ファイルに秘密は無い（設定と秘密は各 Mac の設定のファイルと Keychain にある）ので、誰でも取れてよい。

- タグは `machine-v<版>`（例 `machine-v0.2.0`）。アプリのリリースのタグ・GitHub Release と混ざらないよう接頭辞を分け、GitHub の「Latest」はアプリのリリースに残す（`--latest=false`）。取る側も Latest ではなく、`machine-v*` の一番新しいものを選ぶ
- 1 つのリリースに、3 つの zip（`askhub-worker-<版>-macos-arm64.zip`・`askhub-commander-…`・`askhub-…`）と `SHA256SUMS` を付ける。3 つは同じパッケージから作るので、同じ版で出す
- 出し方（手元の Mac）: `origin/develop` のコミットにタグを作って push → タグを一時の git worktree でビルド → 常時オンの Mac で署名・公証 → 戻ってきた zip を要件で確かめる → `gh release create machine-v<版> --verify-tag --latest=false --draft <3 つの zip> SHA256SUMS` で下書きに資産を付け、4 つそろったのを確かめてから `gh release edit machine-v<版> --draft=false` で出す（上げ損ねた資産が欠けたまま出ないように）。本文には、前の `machine-v*` からの変更と互換の番号を書く
- 出すのは、共同開発者に届けたい区切り（互換の番号を上げたとき・直しを届けたいとき）だけ。自分の Mac には、リリースを待たずに develop のコミットを入れてよい（下の「ワーカーの更新」）

### 司令塔の入れ方（段階 2）

常時オンの Mac で、ログインしているユーザーが端末から流す（ssh からは Keychain を読めない）。

1. `askhub-commander` を置く（ホームフォルダの下。管理者の権限は使わない）
2. `askhub-commander setup --state-repo <owner/repo> --mac <名前> --claude <claude の絶対パス> --first-key <最初の鍵の id> --key-account <GitHub のアカウント> [--github-owner <対象のリポジトリの持ち主> ...]`
   - 設定（秘密を含まない）を `~/Library/Application Support/AskHub/commander/config.json` に書く
   - GitHub のトークン（持ち主ごと）と Claude の setup-token は、端末で伏せて入れ、Keychain（サービス `jp.shilokuma.AskHub.commander`）だけに置く。引数や標準入力では受け取らない。Claude の欄に API キー（`sk-ant-api03-`）が貼られたら断る
   - GitHub のトークンは、持ち主（organization・個人）ごとの fine-grained token にする（下の「GitHub のトークン（持ち主ごと）」）。状態リポジトリの持ち主の分と、`--github-owner` で並べた持ち主の分を順に聞く。状態リポジトリの読み書き（人の意図・質問・ジョブ・生きている印）は状態リポジトリの持ち主のトークン、対象のリポジトリの写し（clone・fetch）と Discussion の写し（作る・直す。[flows.md](flows.md) の「Discussion の写し」）は、そのリポジトリの持ち主のトークンを使う
   - 持ち主のトークンが無いリポジトリは、写しと Discussion の写しが認証の失敗になり、司令塔のログと試行に理由が出る。後から持ち主を足すときは `askhub-commander token <持ち主>` で入れる（設定にも足す。常駐を読み込み直さなくても、次の要求から使い、次の生きている印の自己診断に出る。下の「GitHub のトークン（持ち主ごと）」）
   - 段階 3 で、1 つのトークンから持ち主ごとのトークンに変えた。前の 1 つのトークンからは移さないので、段階 2 で入れた常時オンの Mac は `setup` を流し直す（設定の形も変わったので、流し直すまで `run` は止まる。APNs の設定は残す）。前のトークンは Keychain から消す
   - 公開鍵の記録の最初の鍵を固定する（後から別の鍵には変えられない）
   - 対象のリポジトリは、Discussions を有効にし、カテゴリ「Ideas」（有効にすると GitHub が作る既定のカテゴリ）を残しておく（管理用のトークンがあれば、対象に加えるときに司令塔が有効にする。下の「対象に加えるときの GitHub 側の準備」）。無いあいだは Discussion の写しを書かず、司令塔のログに理由を出す（依頼から開始までの流れは止まらない）
3. `askhub-commander launch-agent` で LaunchAgent の定義を書き、出てくる `launchctl bootstrap` のコマンドで登録する（ログは `~/Library/Logs/AskHub/commander.log`）
4. `askhub-commander xcode <Xcode.app のパス>` で、ビルドとテストに使う Xcode を決める（上の「ワーカーと司令塔の配り方」。決めないと `xcode-select` で選んだものを使い、人が切り替えると変わる）
5. `askhub-commander check` で、設定と Keychain の様子・トークンの期限（値は出さない）・使う Xcode とその版を確かめる
6. 状態リポジトリに見張りを入れる（上の「司令塔の見張り」の「正本と入れ方」）

- git は、司令塔自身を credential helper（`askhub-commander git-credential`）にして、Keychain の GitHub のトークンを受け取る。git に `credential.useHttpPath=true` を渡し、問い合わせの path（`owner/repo.git`）の持ち主でトークンを選ぶ。持ち主のトークンが無ければ何も返さず、理由（トークンの値は出さない）を標準エラーに出す
- 開始のときに常時オンの Mac が選ばれたら、司令塔が作業場所の用意（`prepareWorkspace`）も引き受ける（下の「ワーカーの入れ方」と同じ動き）

### 司令塔の更新

常時オンの Mac の司令塔は、手元の Mac から遠隔で更新する。署名の鍵（Developer ID Application）は常時オンの Mac のログインキーチェーンにだけ置く（社用の Mac などほかの Mac には置かない）。

- 同じ Developer ID と識別子（`jp.shilokuma.askhub.commander`）で署名し続けるので、司令塔の Keychain の項目に一度「常に許可」を付ければ、入れ替えても確認が出ない（署名しないビルドは入れ替えのたびに別のプログラムとみなされ、確認が出ていた）
- ssh のセッションからはログインキーチェーンの署名の鍵を使えない（`codesign` が `errSecInternalComponent` で止まる）。そこで、常時オンの Mac のログイン中のセッションに LaunchAgent（`jp.shilokuma.askhub.deploy`）を置き、署名と差し替えはその中で行う
- 入れ方（常時オンの Mac で 1 回だけ）:
  1. Apple Developer の Certificates で「Developer ID Application」の証明書を作り、常時オンの Mac のログインキーチェーンに入れる（CSR も常時オンの Mac のキーチェーンアクセスで作る）。`security find-identity -v -p codesigning` に出れば済み
  2. 手元の Mac で `scripts/commander/deploy.sh` を流すと、常駐が無ければスクリプトを常時オンの Mac に送り、流すコマンドを出す。それを常時オンの Mac のログイン中の端末で流す（`install-deployer.sh`。LaunchAgent の定義を書いて読み込む）
- 更新: 手元の Mac で `scripts/commander/deploy.sh [ssh の接続先（既定 macmini）]`
  1. 手元でビルドし、署名していないプログラムと、その SHA-256 を書いた依頼（`~/Library/Application Support/AskHub/deploy/request`）を ssh で送る
  2. 常駐が依頼を拾い、SHA-256 を照らし合わせてから Developer ID で署名し、署名とチームを確かめて差し替え（前のものは `askhub-commander.prev` に残す）、司令塔を読み込み直す
  3. 結果は `deploy/last.log`（最後の行が `status=ok` か `status=failed`）。手元のスクリプトがそれを待って出す
- 最初の 1 回だけ、常時オンの Mac の画面に 2 種類の確認が出る。どちらも「常に許可」にする: `codesign` が署名の鍵を使う確認と、署名した司令塔が Keychain の項目（GitHub のトークン・Claude の setup-token・APNs の鍵）を読む確認
- 戻すときは、常時オンの Mac で `askhub-commander.prev` を `askhub-commander` に戻して読み込み直す
- 今の常駐は、司令塔だけを Hardened Runtime なしで署名している。Hardened Runtime を付け、ワーカーと非常口も同じ常駐で署名して手元に戻すように広げる（上の「署名と公証」。#1064）。依頼には役割を書き、識別子は表の 3 つだけを受ける。公証は GitHub Releases に出すときだけ行う（#1065）
- Xcode を上げるときは、新しい Xcode を版の付いた名前（`/Applications/Xcode-27.1.0.app` など）で並べて入れ、動いているジョブが無いときに `askhub-commander xcode <新しい Xcode.app のパス>` で決め直してから読み込み直す。前の Xcode に戻すときも同じ。`xcode-select` は人の作業用に好きに切り替えてよい
  - `/Applications/Xcode.app` を決めると、App Store の更新で中身が入れ替わったときに、ワーカーの Xcode も知らないうちに変わる。版の付いた名前の Xcode を決める

### ワーカーの入れ方（段階 3）

開始のときに人が選ぶ Mac に入れる。ログインしているユーザーが端末から流す（ssh からは Keychain を読めない）。

1. 署名した `askhub-worker` を `~/Library/Application Support/AskHub/bin/` に置く（管理者の権限は使わない）。自分の Mac には手元から送り（下の「ワーカーの更新」）、共同開発者は GitHub Releases から取る（下の「共同開発者の Mac」）
   - この場所は PATH に入っていないので、ここからのコマンドは置いた場所の絶対パスで流す（`"$HOME/Library/Application Support/AskHub/bin/askhub-worker" setup …`。パスに空白があるので引用符で囲む）。LaunchAgent の定義と git の credential helper には、ワーカーが起動した実行ファイルの絶対パスを書く
2. `askhub-worker setup --state-repo <owner/repo> --mac <名前> --kind resident|manual --claude <claude の絶対パス> --first-key <最初の鍵の id> --key-account <GitHub のアカウント> [--github-owner <対象のリポジトリの持ち主> ...]`
   - `--kind` は、LaunchAgent で常駐できる Mac なら `resident`、できない Mac（会社の決まりで launchd に常駐させられない社用の MacBook など）なら `manual`
   - 同時の上限は `--claude-capacity`（既定 2）と `--build-capacity`（既定 1）で変えられる
   - 常時オンの Mac を epic の Mac にも使うときは、司令塔の `setup` でも `--build-capacity 1` を付ける（司令塔の既定は 0 で、ビルドの要る実装のジョブを引き受けない）
   - 設定（秘密を含まない）を `~/Library/Application Support/AskHub/worker/config.json` に書き、トークンは司令塔と同じく端末で伏せて入れ、Keychain（サービス `jp.shilokuma.AskHub.worker`。司令塔とは分ける）だけに置く。最初の鍵は司令塔と同じものを固定する（ジョブの元になった人の意図の署名を、ワーカーも確かめる）
3. 起動する
   - 常駐できる Mac: `askhub-worker launch-agent` で LaunchAgent の定義を書き、出てくる `launchctl bootstrap` のコマンドで登録する（ログは `~/Library/Logs/AskHub/worker.log`）
   - 常駐できない Mac: ターミナルで `askhub-worker run` を流したままにする（ログはそのターミナルに出る）。再起動・ログアウトで止まり、クライアントに「オフライン」と出るので、もう一度流せば続きから再開する
4. `askhub-worker xcode <Xcode.app のパス>` で、ビルドとテストに使う Xcode を決める（司令塔と同じ。決め直したら、常駐を読み込み直すか `run` を流し直す）
5. `askhub-worker check` で、設定と Keychain の様子・トークンの期限（値は出さない）・使う Xcode とその版を確かめる

- `run` は、この Mac が受け持つ epic（開始のときに選ばれた epic）のジョブを 60 秒ごとに読み、自分宛ての `assigned` のジョブを同時の上限の中で引き受けて試行を書く。生きている印（`macs/<mac>.json`）は 10 分ごとに書く。人の意図の処理とジョブの状態の更新はしない（司令塔の仕事）
- 引き受けたジョブは、元になった人の意図の署名を確かめてから実行する。確かめられなければ実行せず、想定外の失敗として人に渡す
- 作業場所の用意（`prepareWorkspace`）では、ワーカー専用のフォルダの clone から epic の作業場所（`work/epics/<epic>/`。ジョブを超えて残す）に作業ブランチ `askhub/<epic の id>` を取り出し、リモートに無ければ `origin/develop` から作って push する（force push しない）。リモートにあれば作り直さずに使う。作業ブランチの名前と先頭のコミットは試行の `outputs` に書く（`epic.json` は司令塔が書く）
- git の credential helper はワーカー自身（`askhub-worker git-credential`）。トークンの選び方は司令塔と同じ

### ワーカーの更新

自分の Mac（ssh で届く Mac）のワーカーは、手元から遠隔で入れ替える（#1064）。

1. 手元で `origin/develop` のコミットをビルドし、常時オンの Mac の常駐に `jp.shilokuma.askhub.worker` で署名させて取り戻す（常時オンの Mac には入れない）
2. 入れる先に ssh で送り、そこで要件（上の「署名と公証」）を確かめ、前のものを `askhub-worker.prev` に残して差し替える
3. `launchctl kickstart -k gui/$(id -u)/jp.shilokuma.askhub.worker` で読み込み直す。ssh のセッションからも、gui の領域の常駐を登録・読み込み直し・外せる（2026-11-12 に MacBook Pro で確かめた。ssh のセッションの中で使えないのは署名と Keychain）。ssh から読み込み直した常駐が Keychain を読めるかは、#1064 の最初の入れ替えで確かめる。読めなければ、司令塔と同じく、ログイン中のセッションの常駐に差し替えと読み込み直しを任せる
4. ログ（`~/Library/Logs/AskHub/worker.log`）の起動の行と、次の生きている印の `versions.worker` で確かめる。`kickstart -k` の後に起動しない（`spawn scheduled` のまま。2026-10-06 に前の仕組みで起きた）ときは、`launchctl bootout` → `bootstrap` する

- 入れ替えは、その Mac に動いているジョブが無いときに行う（読み込み直すと、動いているジョブの試行が止まる）
- 常駐できない Mac（`--kind manual`）は、差し替えた後に、その Mac の人がターミナルの `run` を流し直す
- 戻すときは、`askhub-worker.prev` を `askhub-worker` に戻して読み込み直す
- アドホック署名のワーカーから切り替える最初の 1 回だけ、Keychain の項目ごとに確認が出る（項目を作ったのがアドホック署名のワーカーのため）。その Mac の前にいるときに入れ替え、端末で `askhub-worker check` を流して、出る確認を「常に許可」にする。常駐が読むときにも画面に出るが、誰もいないと答えられないまま止まる
- 共同開発者の Mac は、その人が手で更新する（下の「共同開発者の Mac」）

### 共同開発者の Mac

共同開発者のワーカーは、その人の Mac・その人の GitHub のアカウント・その人の Claude の契約で動かす（[security.md](security.md) の「共同開発者（後から足す）」）。受け入れの仕組み（鍵と GitHub のアカウントの結びつけと書き込み権限の確認・依頼した人の Mac と契約だけでジョブを動かす割り当て・見せる範囲）ができるまでは、自分の Mac にだけ配る。

| 項目 | 共同開発者の Mac での扱い |
| --- | --- |
| Mac | Apple シリコン・macOS 26 以上。版の付いた名前の Xcode（上の「ワーカーと司令塔の配り方」）。`claude` は司令塔と同じ版を 1 か所に入れ、自動の更新を切る |
| GitHub のアカウント | 状態リポジトリ（private）と対象のリポジトリに書ける、共同開発者自身のアカウント。ワーカーのコミット・PR・コメントは、その人の名前で出る |
| GitHub のトークン | 共同開発者が自分のアカウントで、持ち主ごとの fine-grained token を作る（下の「GitHub のトークン（持ち主ごと）」）。ほかの人のトークンを渡さない。organization によっては管理者の承認が要る。organization のメンバーでない人（outside collaborator）が organization を持ち主に選べるかは、受け入れの前に確かめる |
| REST の上限 | アカウントごとに 1 時間 5,000 回なので、共同開発者のワーカーは共同開発者の枠を使い、自分の枠を減らさない。ただし、残りが少ないときの通知は、司令塔が自分のトークンで 1 分ごとに読む分だけ。共同開発者の残りは、その Mac の生きている印（10 分ごと）に出るだけなので、受け入れのときに通知の対象に足す |
| 最初の鍵（`--first-key`） | 司令塔と同じ最初の鍵（状態リポジトリの公開鍵の記録の根。`keys/1.json`）を固定する。共同開発者の端末の鍵は、登録済みの端末で承認して記録に足す |
| `--key-account` | 公開鍵を結びつけてよい GitHub のアカウント。最初の鍵の持ち主と共同開発者の両方を並べる（`--key-account` を重ねる）。司令塔とほかのワーカーの設定にも、共同開発者のアカウントを足す（今は `setup` を流し直すしかない） |
| Claude | 共同開発者の契約で `claude setup-token` を作って入れる。ほかの人の依頼を、その人の契約で処理しない |
| Mac の名前（`--mac`） | 状態リポジトリで重ならない名前にする（`<GitHub のアカウント>-<機種>` など） |

入れ方（#1065 の後）:

1. GitHub Releases から zip を取り、`SHA256SUMS` で照らし合わせる: `gh release download machine-v<版> -R shilokuma-inc/ask-hub-apple -p 'askhub-worker-*.zip' -p SHA256SUMS` → `shasum -a 256 -c --ignore-missing SHA256SUMS`
2. 一時フォルダ（`mktemp -d`）に `ditto -x -k askhub-worker-<版>-macos-arm64.zip <一時フォルダ>` で出し、その中の `askhub-worker` を上の「署名と公証」の要件で確かめる。通ったら `askhub-worker` だけを `~/Library/Application Support/AskHub/bin/` に移す（zip のほかのファイルは使わない。確かめる前に `bin/` へ直接出さない）
3. 上の「ワーカーの入れ方」の 2〜5（`setup`・起動・`xcode`・`check`）

更新:

- 互換の番号が司令塔と合わなくなると、ワーカーがジョブを引き受けなくなり、クライアントに出る（上の「版」）。版が違うだけなら急がない
- `askhub-worker update [<版>]`（#1065）で、一番新しい `machine-v*`（または指定した版）を取り、SHA-256・要件・公証を確かめてから差し替える。常駐なら読み込み直し、ターミナルで流しているなら流し直しを案内する。それまでは、上の入れ方の 1・2 で差し替えて読み込み直す
- 自動では入れ替えない。共同開発者の Mac で動くプログラムを、ほかの人の都合で黙って替えない

### GitHub のトークン（持ち主ごと）

fine-grained token は 1 つの持ち主（organization・個人）のリポジトリしか扱えないので、司令塔とワーカーが扱うリポジトリの持ち主ごとに 1 つ作る（[security.md](security.md) の「トークン」）。classic token は権限を絞れないので使わない（`ghp_` で始まる値は断る）。

1. GitHub の Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token
2. Resource owner に持ち主（organization か自分）を選ぶ。organization によっては、作った後に organization の管理者の承認が要る
3. Repository access は Only select repositories にし、その持ち主の対象のリポジトリ（状態リポジトリの持ち主なら状態リポジトリも）を選ぶ
4. Repository permissions:

   | 権限 | 付け方 |
   | --- | --- |
   | Contents | Read and write |
   | Pull requests | Read and write |
   | Issues | Read and write |
   | Discussions | Read and write |
   | Actions | Read and write（揺らいだ CI の落ちたジョブを流し直すため。ワークフローのファイルは書けない） |
   | Commit statuses | Read-only（commit status で結果を出す CI を読む） |
   | Metadata | Read-only（自動で付く） |
   | Workflows | 付けない（ワークフローのファイルを含む push を GitHub に断らせる。[security.md](security.md) の「public のリポジトリと Secrets」） |

   - Checks の権限は、fine-grained token では選べない（チェックの書き込みは GitHub App だけ）。チェックの結果（check runs）を読む API は、public のリポジトリなら特別な権限なしで読める。private のリポジトリで fine-grained token から読めるかは公式の文書に無いので、private のリポジトリで使う前に確かめる

5. 期限を決めて作り、値（`github_pat_` で始まる）を `setup` か `token <持ち主>` で端末に貼る。値はほかの場所（メモ・チャット・ファイル）に残さない
6. 対象のリポジトリを足したら、そのリポジトリをトークンの Repository access にも足す（持ち主が新しければ、トークンを作って `token <持ち主>` で入れる）。期限が近づいたら作り直して `token <持ち主>` で入れ直す（下の「トークンの期限」）

`token <持ち主>` は、トークンを Keychain に置き、新しい持ち主なら設定の `githubOwners` にも足す。常駐は読み込み直さなくてよい:

- git の credential helper と GitHub の要求（状態リポジトリ・PR・Discussion など）は、要求のたびに Keychain から持ち主のトークンを読むので、次の要求から使う（設定の持ち主の一覧は見ない）
- 生きている印の自己診断（`selfCheck.githubTokens`）は、印を書くたびに設定の `githubOwners` を読み直すので、足した持ち主は次の印（10 分以内）に様子と期限が出る。設定を読めないときは前に読めた一覧のまま。状態リポジトリ（先頭の持ち主）は起動したときのまま

### 管理用のトークン（持ち主ごと）

保護の設定（ルールセット）・Discussions を有効にする・ワークフローのファイルを変える PR などの管理の操作は、毎日のトークン（上の「GitHub のトークン（持ち主ごと）」）ではできない。
毎日のトークンには Administration・Workflows を付けず、常時オンの Mac の司令塔の Keychain に、持ち主ごとの管理用のトークンを別に置く（[security.md](security.md) の「管理用のトークン」。2026-11-12 に決めた）。

- 使うのは司令塔だけで、署名した人の意図を処理するときだけ（保護の設定・対象に加えるときの GitHub 側の準備）。自動では使わない
- git の credential helper（`git-credential`）・Claude のジョブ・ワーカーには渡さない。Keychain の名前（`github-admin-token/<持ち主>`）も読む部品（`GitHubAdminTokens`）も、毎日のトークンとは別にしてある
- 管理用のトークンが無い持ち主のリポジトリへの管理の操作は、「管理用のトークンが無い（`askhub-commander admin-token <持ち主>` で入れる）」の理由で断り、クライアントに出す。毎日の仕事（依頼から最終 PR まで）は止めない

作り方（毎日のトークンと同じ画面で、別のトークンとして作る）:

1. GitHub の Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token。名前は毎日のものと見分けがつくもの（`askhub-admin-<持ち主>` など）
2. Resource owner に持ち主を選ぶ。Repository access は Only select repositories で、その持ち主の対象のリポジトリを選ぶ（状態リポジトリは要らない）
3. Repository permissions:

   | 権限 | 付け方 | 使う所 |
   | --- | --- | --- |
   | Administration | Read and write | ルールセット・クラシックの保護・Discussions を有効にする |
   | Contents | Read and write | ワークフローの直しのブランチとコミット |
   | Pull requests | Read and write | ワークフローの直しの PR を出す・マージする |
   | Workflows | Read and write | `.github/workflows/` のファイルを変える |
   | Discussions | Read-only | カテゴリ「Ideas」があるかを確かめる |
   | Secrets・Environments | Read and write | Secrets の登録（後で足す。付けておけば作り直さなくてよい） |
   | Metadata | Read-only（自動で付く） | |

4. 期限を決めて作り、常時オンの Mac のログインしている端末で `askhub-commander admin-token <持ち主>` を流して貼る（ssh からは Keychain を読めない）。値はほかの場所に残さない
   - 毎日のトークンと同じ値は断る（逆に、`token <持ち主>` に管理用のトークンと同じ値を貼っても断る）
   - 持ち主は設定の `adminOwners` に足す。常駐を読み込み直さなくても、次の管理の操作から使い、次の生きている印（10 分以内）の自己診断（`selfCheck.githubAdminTokens`）に様子と期限が出る。`setup` を流し直しても `adminOwners` は残る
5. 対象のリポジトリを足したら、そのリポジトリを管理用のトークンの Repository access にも足す（足し忘れると、管理の操作が 404・403 で断られる）

### App Store Connect の API キー（配信の検知）

司令塔が App Store での配信を見つけるために読む（[release.md](release.md) の「配信の検知と後作業」）。Upload に使う GitHub の Secrets の鍵とは別に作る。

1. App Store Connect の Users and Access → Integrations → App Store Connect API → Team Keys で、鍵を作る。名前は `AskHub commander` など、役割は **App Manager**（Admin は使わない。審査に出す・配信するなど、人が AskHub で押した操作を後で足すため）
2. .p8 を落とし（一度しか落とせない）、鍵の id（Key ID）と Issuer ID を控える
3. 常時オンの Mac の画面の端末（ssh からは Keychain に書けない）で流す:
   `askhub-commander app-store-connect --key-id <Key ID> --issuer-id <Issuer ID> --key-file <.p8 のパス>`
4. 常駐を読み込み直す（`launchctl kickstart -k gui/$(id -u)/jp.shilokuma.askhub.commander`）。30 分ごとに配信を見回り始める
5. .p8 は Mac に残さず、安全な場所（パスワードマネージャーなど）に移す

- .p8 の中身は Keychain（`app-store-connect-key/<Key ID>`）にだけ置き、設定（`config.json` の `appStoreConnect`）には鍵の id と Issuer ID だけを書く。`setup` を流し直しても残す
- Apple のチームが複数あれば、チームごとに 1 つ足す（同じ Key ID で流し直すと置き換える）。どのチームのアプリかは、アプリの Bundle ID を鍵ごとに探して決める
- 鍵の設定が無ければ配信を見つけない（起動のログに出る。前に見つけた版の後作業だけは進める）。`askhub-commander check` で鍵の様子（値は出さない）を確かめる
- 鍵を取り消したら、見回りは 401 で止まり、ログに出す。作り直して流し直す

### トークンの期限

GitHub のトークン（持ち主ごと）と Claude の setup-token には期限がある。切れると、その Mac の仕事（状態リポジトリのトークンなら生きている印も）が止まるので、司令塔とワーカーが期限を生きている印の自己診断に書き（値は書かない。[protocol.md](protocol.md) の「macs/<mac>.json」）、クライアントで知らせる。

- GitHub のトークン: 生きている印を書くたび（10 分ごと）に、持ち主ごとのトークンで GitHub の `/rate_limit`（REST の上限に数えられない）を呼び、応答の見出し `github-authentication-token-expiration`（`2027-10-23 12:25:03 UTC` の形）から期限を読む
  - 見出しが無いのは、期限の無いトークン。401 が返ったら使えない（前に読んだ期限を過ぎていれば期限切れ）。つながらないときは前に読んだ期限のまま
  - 問い合わせる持ち主は、印を書くたびに設定（`githubOwners`）から読み直す。`token <持ち主>` で足した持ち主も、読み込み直さずに次の印から期限が出る
- 管理用のトークン（司令塔だけ）: 毎日のトークンと同じ読み方で、設定の `adminOwners` の持ち主ごとに期限を読み、自己診断の `githubAdminTokens` に書く。毎日のトークンのまとめ（`githubToken`）には入れない。上限の残りを見る 1 分ごとの問い合わせには使わない
- Claude の setup-token: 作った日から 1 年使える。`setup`・`claude-token` で新しい値を入れた日を `~/Library/Application Support/AskHub/<役割>/claude-token.json` に記録し（日付だけ）、その 1 年後を期限とする
  - 記録を始める前に入れた setup-token は、期限が分からない（クライアントに「期限は分かりません」と出る）。`claude setup-token` で作り直して `claude-token` で入れると記録される
- クライアントは、Mac の画面にトークンごとの残り日数を出す
  - 期限まで 14 日を切ったら、「あなたの番」（時間のあるときに）に入れ直すコマンドを出す
  - 期限が切れた・使えないトークンは、進行を止めるものとして「止まっています」と出す（状態リポジトリのトークンが切れた Mac は印を書けずにオフラインになるが、オフラインが 7 日を超えるまでは出す）
  - 管理用のトークンは、切れても毎日の仕事は止まらないので、「止まっています」にはせず、「あなたの番」（時間のあるときに）に「管理用のトークンを入れ直す」と出す。Mac が新しいループを受けない理由にもしない
- 入れ直し（その Mac の端末で流す。常時オンの Mac は `askhub-commander`、ほかの Mac は `askhub-worker`）

  | トークン | 作り直し | 入れ直すコマンド |
  | --- | --- | --- |
  | GitHub（持ち主ごと） | 上の「GitHub のトークン（持ち主ごと）」の 1〜5（Regenerate でもよい） | `token <持ち主>`。常駐を読み込み直さなくても、次の要求から使い、次の印の自己診断に期限が出る |
  | 管理用（持ち主ごと。常時オンの Mac だけ） | 上の「管理用のトークン（持ち主ごと）」の 1〜4（Regenerate でもよい） | `askhub-commander admin-token <持ち主>`。読み込み直さなくてよい |
  | Claude の setup-token | 人の Mac で `claude setup-token` | `claude-token`。常駐のループは起動したときの値を使うので、読み込み直す（`launchctl kickstart -k gui/$(id -u)/jp.shilokuma.askhub.commander`、ワーカーは `…askhub.worker`。ターミナルで流しているワーカーは流し直す） |

- `check` で、持ち主ごとの GitHub のトークン・管理用のトークン（司令塔）と Claude の setup-token の期限を確かめられる

### 非常口（`askhub`）

クライアントが壊れても人の意図を出せるように、Mac の端末から署名して送るコマンド。鍵は Secure Enclave（無ければソフトウェアの鍵）に作り、GitHub のトークンと一緒にその Mac の Keychain（サービス `jp.shilokuma.AskHub.cli`。司令塔とは分ける）だけに置く。段階 2 の試運転では、クライアントのつなぎ込みの前に、これで依頼から開始の待ちまでを通しで動かす。

1. `askhub setup --state-repo <owner/repo>`: 設定を書き、GitHub のトークン（状態リポジトリを読み書きできるもの）を端末で伏せて入れ、署名の鍵を作る
2. `askhub key register-first --account <GitHub のアカウント> --label <名前>`: 公開鍵の記録が空のときに、この鍵を最初の鍵（`keys/1.json`）として登録する。出てくる鍵の id を、司令塔の `setup --first-key` に渡す
   - ほかの端末の鍵は `askhub key add --public-key <base64url> --account … --label …`、取り消しは `askhub key revoke <鍵の id>`
3. `askhub add-repository --repo <owner/repo>` → `askhub configure-repository --repo … --file <build.json>`（下の「ビルドの設定の入れ方」。開始の前に要る）→ `askhub request --repo … --title … --body …`
4. `askhub status` で epic・答える質問（id と版と選択肢）・ゴール・送った意図の処理の結果を見て、`answer`・`clarify`・`decide-split`・`revise-goal`・`start` で進める
   - 続けて見張るときは `askhub status --watch 60`（間隔は 60 秒以上。中身が変わったときだけ出す。Ctrl-C で止める）。1 つのプロセスで読んだものを使い回すので、変わらない周は GitHub の上限に数えられない
   - 外のループ（`while … sleep`）で `askhub status` を流さない。読んだ tree と blob は Caches に持つが、1 回ごとに少なくとも直下の一覧の 1 回を上限に数えられ、間隔の下限も無い
5. 要らなくなった依頼は、開始する前なら `askhub abandon --repo … --epic …` で取り下げる（開始した後の取り下げは段階 4 の 3 で足す。[flows.md](flows.md) の「開始した後の取り下げ」）。開始した後の一時停止・再開・引き継ぎは、上の「Mac の一時停止・再開・引き継ぎ」
6. 人の対応待ちのジョブ（認証切れ・想定外の失敗など）は、`askhub status` に失敗の理由と、`retry`（やり直す）・`give-up`（やめる）に渡す引数（ジョブの id と試行の番号）が出る。原因を直してから `retry` を送る

## GitHub の上限

GitHub の REST の上限（1 時間に 5,000 回）は、トークンごとではなくアカウントごとに数える。司令塔・クライアント・Claude のセッションの `gh` が同じアカウントなら、同じ 5,000 回を分け合い、使い切ると戻るまで全部が止まる（2026-11-11 に、`askhub status` を短い間隔で流すループで使い切った）。人が早く気づいて止められるよう、残りを見せて知らせる。

- 司令塔は、1 分ごとに持ち主ごとのトークンで `/rate_limit`（REST の上限に数えられない）を呼び、本文の `resources.core` から残りと戻る時刻を読む（`AskHubCommander` の `CommanderLoop`・`GitHubTokenExpiry`）
  - 生きている印（10 分ごと）の自己診断に、持ち主ごとに書く（[protocol.md](protocol.md) の「macs/<mac>.json」）
  - 残りが 1,000 回（`GitHubRateLimit.lowRemaining`）を切ったら、その窓（戻る時刻）で 1 回だけ、生きている印をすぐ書き直し、通知を送る（上の「通知」）。文は「GitHub の残りが少なくなりました」「残り 820 回（1 時間 5,000 回）。15:54 に戻ります。askhub status のループなど、GitHub を多く使うものを止めてください」。タップで司令塔の Mac を開く
  - 使い切った後は、状態リポジトリに書けない（通知の記録も書けない）ので知らせられない。知らせるのは使い切る前だけ
- `askhub-commander check` に、今の残りと戻る時刻が出る
- クライアントは、上限に当たったら（状態の読み込みが 403・429 で `retryAfter` が分かったら）、言われた時刻まで自動の取り直しと受け付けの確かめを休み、接続の行に「GitHub の上限に当たりました」「15:54 に戻ります」と出す（`ClientStore+Refresh`）。休む間は「もう一度読む」を出さない（読んでも弾かれる）
  - 取り直しの間隔は、前の読み込みを終えてから数える。Mac で前面でない間と、残りが 1,000 回を切っている間は 30 秒を 2 分に延ばす（最後の残りを司令塔に回す）。前面に戻ったら、間隔が空いていればすぐ読む
- クライアントは、Mac の生きている印に書かれた残りのうち、一番新しく読んだ今の窓のもの（戻る時刻を過ぎたものは使わない）を出す
  - 接続の行（「あなたの番」の上。Mac・iPad ではサイドバーの下）の 2 行目に「GitHub の残り 4,210 回」と小さく添える
  - 1,000 回を切ったら、接続の行を「GitHub の残りが少なくなっています（820 回）」「15:54 に戻ります。GitHub を多く使うものを止めてください」の警告にする
  - Mac の詳細の「GitHub の上限」に、その Mac が読んだ残り・上限・戻る時刻と、読んだ時刻（印は 10 分ごとなので、最大 10 分前の値）を出す
- 減っているときに探すもの: Claude のセッションの `gh`・`askhub status` のループ（[LEARNINGS.md](../../LEARNINGS.md) の「GitHub」）。使われ方は `gh api rate_limit` の `used` の 1 分ごとの増え方で測る（これも上限に数えられない）

## 容量

- ワーカーは、自分で作ったもの（worktree・Simulator・DerivedData）を、最終 PR のマージ後に自動で片付ける
- 片付け（`cleanUp`）は epic の Mac だけで動くので、司令塔とワーカーは、生きている印を書いた後の見回りで、終わった（マージした・やめた）epic の、自分のフォルダに残った作業場所・手元のブランチ・DerivedData を消す。常時オンの Mac で最終 PR を直した epic、片付けを見張る間（マージから 7 日）に epic の Mac が戻らなかった epic、開始した後にやめた epic のものが当たる
  - 消すのは、状態リポジトリで終わったと確かめられ、終わってから 1 日たった epic のものだけ（終わった直後に、人が残りものを確かめられるよう少し残す。読めない・見つからない epic のものは残す）
  - ジョブが作業場所を使っている epic は、待たずに次の見回りに回す。Simulator の枠は epic をまたいで使い回すので触れない
- Simulator は、ワーカーの中の枠ごとに決まった名前（`askhub-` で始まる）で作り、使い回す。動いているループに属さないものは、定期的な見回りで消す（段階 4 の 6 で見回りにつなぐ。部品の `SimulatorPool.removeStray` はある）
  - テスト（`testLight`・`testFull`）と撮影の前に、起動していた枠の Simulator を止めてから起動し直す。前の回の UI テストが横向きにした端末の向きは、起動している間ずっと残り、`simctl` では読めも戻せもしないため
    （2026-11-11 に、横向きのまま残った枠の Simulator で、最終 PR の前の検証の UI テストが 3 回続けて落ちた）。起動し直すのは 1 回 13〜22 秒ほど（手元の Mac の iOS 26.5 で測った）。ビルドだけなら起動し直さない
  - 起動し直した後に、外観（ダークモード）も `simctl ui <UDID> appearance` で読み、ダークならライトに戻す。外観は止めて起動し直しても残り、LaunchTests の雛形（構成ごとの実行）はダークにもするため。
    外観に対応しないランタイム（`unsupported`）はそのまま使う。読むのは `simctl` 1 回分で、起動し直すのに比べて小さい
- clone 本体は、最後に使ってから 7 日で消す。空き容量が少なければ早めに消す
- 常時オンの Mac は、段階 0 の時点で空きが約 15 GB しかなく、今の仕組みのループが作った Simulator（約 34 GB）と DerivedData（約 21 GB）が場所を取っている。切り替えの準備で、今の仕組みを止めた後に片付ける
- ワーカーが作っていないもの（手で作った clone・Simulator）は、クライアントに「片付けの候補」として出し、人が選ぶ。探すのは、人がクライアントで「探す」を押したときだけ。消す前に、未コミット・未 push・stash が無いかを確かめる（段階 4 の 6 で作る。今はデモのデータだけ）
- 各 Mac の空き容量を生きている印に書き、クライアントに出す。空きが一定以下なら、その Mac は新しいループを受けずに知らせる（受けない判定は段階 4 の 6 で作る。今は書いて出すだけ）

## Claude の利用上限

- 利用上限は契約ごとに来る（[architecture.md](architecture.md)）。上限に達したら、解除の時刻まで待って再開する
- 無人の実行の使用率（5 時間・週の枠の何 % か）を読む公式の手段は無い。クライアントに出せるのは、ワーカー自身の使用量の見積もりと、上限に達したときの解除の時刻だけ（使用率の表示は切り替えの後に回す）
- 1 回の呼び出しの暴走は、時間の上限と `--max-budget-usd` で止める（`--max-budget-usd` は段階 4 の 6 で足す。今は時間の上限だけ）

## 対象のリポジトリ

- 機能の依頼でリポジトリを選ぶときは、対象のリポジトリだけを出す
- 「対象に加える」でリポジトリを選ぶときは、まだ対象になっていないものだけを出す（段階 4 の 4 で作る。今はデモのデータだけで、状態につないだときは owner/name を手で入れる）
- どちらも検索できるようにする
- 対象に加えるときは、設定を状態リポジトリに書き、GitHub 側の準備をする（下の「対象に加えるときの GitHub 側の準備」）。ブランチ保護は人が押したときだけ設定する
- リポジトリの新規作成は、「テンプレートからの複製」と「対象に加える」と同じ手順の組み合わせにして、できあがるものをそろえる（下の「テンプレートからの新規作成」）
- 管理の操作（Discussions を有効にする・保護の設定・作成・ワークフローのファイルを変える PR・Secrets の登録）は、毎日のトークンではなく、管理用のトークンで行う（[security.md](security.md) の「管理用のトークン」）

### 対象に加えるときの GitHub 側の準備

2026-11-12 に決めた。司令塔が `addRepository` の処理で、管理用のトークン（上の「管理用のトークン（持ち主ごと）」）で行い、結果を `repo.json` の `setup` に書く（[protocol.md](protocol.md) の「repo.json」）。

- **Discussions**: 無効なら有効にする。カテゴリ「Ideas」（有効にすると GitHub が作る既定のカテゴリ。Discussion の写しに使う）があるかを確かめ、無ければ `setup.discussions` を `missingCategory` にし、クライアントが人がする作業として出す（API ではカテゴリを作れない。GitHub のリポジトリの Discussions の画面でカテゴリを作る）
- **ワークフローのファイル**: 今の仕組みのワークフロー（`close-goal-discussion.yml` と、ralph-kit を呼ぶもの）を外し、待つチェックのワークフローの `push`・`pull_request` の `paths`・`paths-ignore`（とそのすぐ上のコメント）を外す、決まった手順の PR を出す（下の「既存のリポジトリを移すとき」）
  - 待つチェックのワークフローは、ビルドの設定の `childChecks`・`finalChecks`（まだ無ければ `build / build`）の ` / ` の前の名前のジョブを持つもの。待たないワークフロー（Upload など）は絞ったままにする
  - ブランチは `askhub/setup-workflows`、base はビルドの設定の `baseBranch`（無ければ既定のブランチ）。前に出した PR が開いていれば出し直さない。直すところが無ければ PR を出さない（`setup.workflows.state` が `notNeeded`）
  - ワーカーのトークンは Workflows を持たないので、ふだんの epic では push できない。司令塔の管理用のトークンで出す（コミットの書き手は、トークンのアカウント）
  - PR は自動ではマージしない。人がクライアントで承認する（`approveSetupPullRequest`。見たときの head に結びつき、承認の後に push されたらマージしない）と、司令塔が管理用のトークンで merge commit にする。必須のチェックが通っていなければ、理由を付けて断る（CI が通ってから承認し直す）。GitHub の画面でマージしてもよい
  - YAML は行で読んで直す（`on:` の下のイベントの下のキーだけ）。決まった形でない書き方は直さないので、直すところが残れば準備の依頼で直す
- **管理用のトークンが無い持ち主**: 加えるのは受け付け、準備だけ止めて `setup.problems` に理由を書く（2026-11-13 にユーザーが決めた）。管理用のトークンを入れた後に、もう一度 `addRepository` を送る（クライアントの「準備をやり直す」）と流し直す。Discussions を有効にできない・PR を出せないなども、`setup.problems` に理由を書く
- **ほかの中身**（CLAUDE.md の `## 全員向けの事実` の節・ループの中継のスクリプト・今の仕組みの設定・CI の `epic/**` を `askhub/**` に読み替える）は、加えた後にクライアントが「準備の依頼」の下書きを出す。人が確かめて送り、ふだんの epic（質問 → ゴール → 子 PR → 最終 PR）で直す。リポジトリごとに違う残りものを、Claude が読んで直せるように
  - ワークフローのファイル（`epic/**` の読み替えを含む）は、ワーカーが push できないので、epic では直せない。準備の依頼の下書きには、人が GitHub で直すことを添える（2026-11-13 にユーザーが決めた。決まった手順の PR には入れない）
- 保護は、加えるときには掛けない。人がクライアントで「保護の設定」を押したとき（`applyProtection`）だけ掛ける。既存のクラシックの保護・独自のルールセットは、そのときに新しいルールセットに置き換えて外す（[plan.md](plan.md) の「残りのリポジトリの移し方」）。掛けた後のずれは定期的に点検して知らせる（下の「保護の設定」）
- 非常口: 準備の PR の承認は `askhub approve-setup --repo <owner/repo> --pr <番号> --head <PR の head>`（番号と head は `repo.json` の `setup.workflows`）

### 保護の設定

人がクライアントで「保護の設定」を押したとき（`applyProtection`）だけ、司令塔が管理用のトークン（上の「管理用のトークン（持ち主ごと）」）で掛ける。自動では掛けない（[security.md](security.md) の「ブランチ保護」）。

- 掛けるもの: ルールセット `askhub-protect`（`ProtectionPolicy`）。対象は develop・main・`release/**` で、PR 必須（承認は 0。同じアカウントでは承認できないため）・必須のチェック（GitHub Actions が出したもの）・force push と削除の禁止、例外（bypass）なし。`release/**` を作るときは必須のチェックで止めない（`do_not_enforce_on_create`）。移行のときに手で掛けてきたものと同じ中身
- 必須のチェック: 押す画面で、そのリポジトリのビルドの設定の `childChecks`（無ければ `build / build`）を既定に入れ、人が直して送る（2026-11-13 にユーザーが決めた）
- 順: 先にルールセットを掛けて（同じ名前のリポジトリのルールセットがあれば置き換える）から、重なる保護を外す。途中で失敗しても、保護が無い時間を作らない
  - 外すのは、develop・main・`release/**` と既定のブランチに重なる、クラシックの保護とリポジトリのルールセットだけ。ほかのブランチ（`gh-pages` など）の保護は残す（2026-11-13 にユーザーが決めた）
  - organization のルールセットは、リポジトリの側からは外せないので、残ったものとして `repo.json` の `protection.remaining` に書き、クライアントに出す
  - 重なるかは、守るブランチの例（develop・main・`release/1.0.0`・`release/x`・既定のブランチ）に合うかと、`release/` で始まるパターンかで見る
- 書くもの: `repo.json` の `protection` に、掛けた時刻・必須のチェック・ルールセットの id・外したもの（`replaced`）・残ったもの（`remaining`）。重なる保護を外しきれなかったときは、書いた上で理由を付けて断る（押し直すと残りを外す）
- 断るとき（理由をクライアントに出す）: 管理用のトークンが無い・使えない、管理用のトークンの Repository access にそのリポジトリが無い、private のリポジトリ（今の組織のプランではルールセットを掛けられない。GitHub が 403 で「Upgrade to GitHub Pro …」と返す）、GitHub に届かない（押し直す）
- ずれの点検: 保護を掛けたリポジトリを 6 時間ごとに、毎日のトークン（Metadata の読み取り。管理用のトークンは自動では使わない）で読み、`askhub-protect` が外された・有効でない・対象のブランチや規則や必須のチェックが変わった・例外が足された・ほかのリポジトリのルールセットが重なった、を `protection.drift` に書く。ずれの中身が変わったときだけ書く。直すのは、人が保護の設定を押し直したとき
  - 毎日のトークンではクラシックの保護を読めない（Administration が要る）ので、あとから足されたクラシックの保護はずれに出ない。例外（bypass）も、管理の権限が無いと見えないので確かめられないことがある
- 非常口: `askhub apply-protection --repo <owner/repo> [--checks <名前,名前>]`
- 掛けると、develop・main への直接の push（`GITHUB_TOKEN` のワークフローを含む）は止まる。ask-hub-apple の今の仕組みの Release/*（main・develop に直接 push していた）は #1087 で外したので、ask-hub-apple にも掛けられる。ほかのリポジトリも、直接 push するワークフローが残っていないかを確かめてから押す

### 対象から外す

2026-11-12 に決めた。段階 4 の 4 で作る。

- 終わっていない epic（`merged`・`abandoned` 以外）があれば断る。先に取り下げてもらう（理由に epic を出す）
- 状態リポジトリの `repos/<owner>/<repo>/` は消さない。`repo.json` に外した印を付けて残す（形は [protocol.md](protocol.md) に書く）。終わった epic は、ほかと同じく 30 日後に `archive/` へ移して畳む
- 外したリポジトリへの依頼・開始・ビルドの設定は断る。クライアントの一覧から外し、「対象に加える」の候補に戻す。もう一度加えると印を外して戻る（ビルドの設定も戻る）
- GitHub 側（ルールセット・Discussions・ワークフロー）には触れない

### テンプレートからの新規作成

2026-11-12 に決めた。段階 5 の共通リポジトリを待たず、段階 4 の 5 で作る。今の仕組みでは、依頼の「新しいアプリ」から作っていた（2026-10 に 4 本）。

1. 先に、テンプレート（template-app-ios・visionOS のもの）から今の仕組みの跡（ralph-kit を呼ぶワークフローとスクリプト・CLAUDE.md のループの節など）を外す
2. クライアントで、テンプレート・持ち主・名前・公開範囲を選んで送る（作る意図。名前は実装で決める）。司令塔が管理用のトークンで、テンプレートからリポジトリを作る
3. 作った後は、「対象に加える」と同じ準備（上の「対象に加えるときの GitHub 側の準備」）と、ビルドの設定を流す
4. App Store Connect でしかできない作業（アプリの新規作成など）は、人がする作業のチェックリストで出す（[release.md](release.md) の「App Store Connect でしかできない作業」）

- 共通リポジトリ（段階 5 の 5）ができたら、テンプレートも共通リポジトリのワークフローを呼ぶ形に作り直し、作ったリポジトリもほかと同じく移す

### ビルドの設定の入れ方

ワーカーは、リポジトリのビルドの設定（`repo.json` の `build`。形は [protocol.md](protocol.md) の「repo.json」）でビルド・テストを流し、子 PR と最終 PR のチェックを待つ。設定が無いリポジトリでは、司令塔が開始を断る。対象に加えた後に、人が入れる（直すときも同じ）。

1. 設定の JSON を書く（`repo.json` の `build` と同じ形）

   ```json
   {
     "baseBranch": "develop",
     "xcode": {
       "project": "PrimePick.xcodeproj",
       "scheme": "PrimePick",
       "destinations": [{ "platform": "iOS", "deviceType": "iPhone 17 Pro", "osVersion": "26.5" }],
       "testLight": { "onlyTesting": ["PrimePickTests"] },
       "testFull": { "testPlan": "Full" }
     },
     "childChecks": ["build / build"],
     "finalChecks": ["build / build", "ui-test / ui-test"],
     "trustedReviewers": ["coderabbitai[bot]"],
     "screenshots": {
       "scenes": "PrimePickApp/Screenshot/screenshot-scenes.json",
       "destination": { "platform": "iOS", "deviceType": "iPhone 17 Pro", "osVersion": "27.0" }
     }
   }
   ```

   - `baseBranch` は作業ブランチの元で、最終 PR の向き先（無ければ develop）
   - `xcode` の値は `xcodebuild` の引数になる。`project` はリポジトリの直下からの相対パス。`.xcodeproj` をコミットせず XcodeGen で作るリポジトリは `"generate": "xcodegen"` を足す（ワーカーがビルド・テスト・スクショのビルドの前に、作業場所の直下で `xcodegen generate` を流す。ワーカーの Mac の `/opt/homebrew/bin`・`/usr/local/bin`・`~/.local/bin` のどれかに `xcodegen` が要る）。`destinations` は並べた順に流す（macOS は `{ "platform": "macOS" }`。`osVersion` を省くと、使う Xcode の SDK と同じか古いランタイムのうち最新）。`testLight`（子 PR の前）・`testFull`（最終 PR の前。UI テストを含む）は、省くと全部のテスト
   - `childChecks`・`finalChecks` は、待つチェックの名前（1 つ以上）。PR の画面のチェックの表示と同じで、再利用ワークフローのジョブは `build / build` の形になる。develop の最近のコミットのチェックの名前は `gh api repos/<owner>/<repo>/commits/develop/check-runs --jq '.check_runs[].name'` で見られる
   - `trustedReviewers` は、指摘を Claude に渡してよいレビューの書き手（無ければ空。CodeRabbit は最終 PR でだけ待つ）
     - CodeRabbit が入っていない organization のリポジトリには `coderabbitai[bot]` を入れない（下の「既存のリポジトリを移すとき」の「信用するレビューの書き手」）
   - `screenshots` は、判断のカードのスクショの撮り方（無ければ撮らない。下の「判断のカードのスクショの入れ方」）
2. 非常口から送る: `askhub configure-repository --repo <owner/repo> --file build.json`。送る前に、司令塔と同じ決まり（`-` で始まる値・リポジトリの外を指すパス・知らない欄・チェックが空）で確かめ、合わなければ送らない。
   新しく足した欄（`generate` など）は、古い司令塔には知らない欄なので、先に司令塔を更新してから送る
3. `askhub status` で、送った意図が受け付けられたか（断られたら理由）を見る。送るたびに `build` をまるごと置き換える

- クライアントでの入れ方は、段階 4 の 4 で作る（今は非常口の `askhub configure-repository` だけ）

### 判断のカードのスクショの入れ方

最終 PR の見える仮決めのカードに Before / After のスクショを付けるには、リポジトリに撮れる画面の一覧を置き、ビルドの設定に `screenshots` を足す（仕組みは [flows.md](flows.md) の「スクショ」）。

1. アプリに、起動引数でデモのデータの画面を開く仕組みを用意する。template-app-ios 由来のリポジトリは、App Store のスクショの撮影モード（`ScreenshotDemo`。`-screenshot-demo -screenshot-scene <scene>`）がそのまま使える。
   無いリポジトリは、デモのデータ（実データ・個人情報・トークンを含まない）と、起動引数で開く画面を先に作る（AskHub に依頼してループで作ってよい）
2. 撮れる画面の一覧の JSON をリポジトリに置く（形は [protocol.md](protocol.md) の「撮れる画面の一覧」）。最初は App Store のスクショと同じ画面だけでよい。足りない画面・状態は、epic の中で実装する Claude が足す

   ```json
   {
     "v": 1,
     "scenes": [
       { "id": "main", "title": "タイトル画面", "arguments": ["-screenshot-demo", "-screenshot-scene", "main"] },
       { "id": "quiz", "title": "練習モードの出題中", "arguments": ["-screenshot-demo", "-screenshot-scene", "quiz"] }
     ]
   }
   ```

3. 手元で開けるかを確かめる: Simulator にアプリを入れ、`xcrun simctl launch <UDID> <Bundle ID> <arguments…>` で各画面が開くか見る（撮るのはワーカーが Debug でビルドしたアプリ）
4. ビルドの設定の JSON に `screenshots`（一覧のパスと撮る Simulator）を足して、`askhub configure-repository` で送り直す（`build` はまるごと置き換わるので、今の設定に足して送る）

- 撮った画像は最終 PR の本文（public）に載り、消せない。一覧には、デモのデータの画面だけを書く
- アプリの中の時刻の文（「9:41 に確かめました」など）は、撮る時刻で変わる。Before と After をそろえるため、デモの時計を止める起動引数（ask-hub-apple は `-demoClock 2026-01-15T00:41:00Z`）も一覧の画面に渡す
- 一覧の画面の `id` は変えない（変えると Before と比べられなくなる）

### 既存のリポジトリを移すとき

今の仕組みで管理しているリポジトリは、作りがそろっていない（段階 0 の後の調査）。「対象に加える」で次も扱う。

- **ビルドの設定**: プラットフォーム、テストの行き先（Simulator の種類）、プロジェクトの作り方（XcodeGen なら生成してから）、スキームをリポジトリごとに持つ。ワーカーはこれでビルドとテストを流す（上の「ビルドの設定の入れ方」。XcodeGen で作るリポジトリは `generate`）
- **CI のチェックの名前**: 子 PR で待つ必須のチェックの名前はリポジトリごとに違うので、決め打ちにしない（ルールセットか、develop の最後の回から読んで、ビルドの設定の `childChecks`・`finalChecks` に入れる）
- **待つチェックの起動の条件**: `childChecks`・`finalChecks` のチェックを出すワークフローは、`paths`・`paths-ignore` で絞らない。絞っていると、ドキュメントだけのタスクの子 PR（最終 PR も）でチェックが出ず、ワーカーが 30 分待って「始まらない」（unexpected）の失敗で人に渡す。
  ルールセットで必須にしたチェックも、出なければ PR をマージできない。絞っていたら、外す PR を移すときに出す（shariverse/oshikatsu-countdown-ios#161、shilokuma-inc/ask-hub-apple#997）。待たないチェック（ubuntu の軽い検査など）は絞ってよい
- **信用するレビューの書き手**: ビルドの設定の `trustedReviewers` に `coderabbitai[bot]` を入れるのは、その organization に CodeRabbit が入っているときだけにする。入れると、ワーカーは最終 PR のレビューで CodeRabbit が始まるのを待つので、入っていなければ最終 PR ごとに 15 分（`FinalReviewTiming` の `reviewerStartLimit`）待ってから進む。
  入っているかは、organization に入っている GitHub App の一覧に `coderabbitai` があるかで見る（`gh api orgs/<owner>/installations --jq '.installations[] | {app_slug, repository_selection}'`。organization の owner のトークンで読める）。
  `repository_selection` が `selected` なら、organization の設定の GitHub Apps で、そのリポジトリが選ばれているかも見る。tm-family には入っていなかったので、3 本とも空にした
- **作業ブランチの名前**: 今の仕組みの CI は、統合ブランチ `epic/**` を前提に書いてある（子 PR は PR のイベントで Build を動かさない・最終 PR だけ更新でも UI テストまで流す・concurrency のグループ・`.coderabbit.yaml` の子 PR の除外）。
  新しい仕組みの作業ブランチは `askhub/<epic の id>`、子ブランチは `askhub/<epic の id>-<タスクの id>` なので、`epic/` を `askhub/` に読み替える。読み替えないと、子 PR が push と PR のイベントで 2 回（PR のほうは UI テストまで）流れ、macOS のランナーの枠を食う
- **ワーカーの Xcode**: 各リポジトリの CI は Xcode を固定している（2026-11 は 26.6）が、ワーカーはその Mac の設定で決めた Xcode（`xcode`。決めていなければ `xcode-select` で選んだもの。Mac mini は 27.1）でビルドとテストを流す。27.1 は Swift の並行性のチェックが厳しく、CI で通るコードが落ちることがある
  （shariverse/dokogacha-app-ios は `DGDashedLine.swift` の `Shape` への準拠が `#ConformanceIsolation` で落ちる）。移す前に、ワーカーと同じ Xcode で `build` の設定と同じ `xcodebuild build-for-testing` を流して確かめ、落ちたら移す前に直す
  - 直し方の例: tm-family/shinkeisuijaku-app-ios も `StampView.swift` の `LockShape` の `Shape` への準拠が同じく落ち、型に `nonisolated` を付けて（`nonisolated struct LockShape: Shape`）直した（tm-family/shinkeisuijaku-app-ios#76）。`Shape` の要件は隔離が無いので、既定の MainActor から外す。この書き方は 26.6 でも通る
- **非常口の Keychain の確認**: `askhub add-repository`・`configure-repository` を送るために develop からビルドし直した `askhub` は、署名が変わるので、初回に Keychain（サービス `jp.shilokuma.AskHub.cli`）の項目を読む確認が出る。許可すれば続けて使える
- **共通リポジトリの前の期間**: 共通リポジトリ（段階 5）ができるまでは、各リポジトリの今のワークフローを入れ替えずに使う
- **今の仕組みの残りもの**: ラベル・状態用の Issue・ループの中継のスクリプト・CLAUDE.md のループの節を外す PR を、移すときの手順に入れる（段階 4 の 4 からは、上の「対象に加えるときの GitHub 側の準備」で行う）
- **移管・改名**: 状態リポジトリのパスは owner/name なので、リポジトリの移管・改名に追って、状態のファイルを移す
- **App Store Connect の鍵**: Upload の鍵は、今どおり GitHub の Secrets に置く（今は organization の Secrets。Environment の Secrets に移すのは #1067）。App Store Connect の状態を読む鍵は、常時オンの Mac の Keychain に置き、司令塔が読む（2026-11-12 に決めた。[release.md](release.md) の「ワークフロー」）
- **Apple 以外の部品**: backend などを持つリポジトリは、ワーカーの検証に足すか、その部分の変更を人に回すかを、移すときに決める

## 共通リポジトリとテンプレートの配布

- CI・リリースのワークフローと道具は、共通リポジトリ（public）から配る。各リポジトリには、GitHub Actions の再利用ワークフローを呼ぶ薄いファイルと、小さな設定ファイル（スキーム・プラットフォームなど）だけを置く
- 呼ぶ版は固定したコミット（または保護したタグ）にし、クライアントから上げる。新しい版は 1 つのリポジトリで試してから広げる。どのリポジトリがどの版かをクライアントに出す
- テンプレートに残すのは、アプリの骨組み（プロジェクト・画面の雛形）だけにする
- 切り替えのときに、今あるリポジトリにも「対象に加える」と同じ手順を流し、ワークフローと設定をそろえる
- プロジェクトを設定ファイルから作る道具（XcodeGen を候補にする）に移し、Widget や App Clip のターゲットの追加もループでできるようにする。テンプレートの配布の段階で、ターゲットを足す頻度を見て決め直す
- 各リポジトリの CLAUDE.md は、「全員向けの事実」と「人のセッション向けの手順」に分ける。ワーカーの Claude に渡す規則は、ワーカーの中に持つ
  - 全員向けの事実は `## 全員向けの事実` の見出しの下に書く。見出しがあればその節だけを、無ければ CLAUDE.md 全体を Claude に渡す
