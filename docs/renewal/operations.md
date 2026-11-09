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
  - リジェクトは、審査の状態を状態リポジトリに持つ段階 5 で足す
- 同じ出来事は二度送らない。知らせた出来事を `notifications.json` に記録し（[protocol.md](protocol.md)）、記録を書けたときだけ送る
  - 見直して版が変わった質問・説明ができた質問・直したゴール・次の試行で人に渡したジョブ・一度戻ってからまた止まった Mac は、別の出来事として知らせ直す
  - 最終 PR の確認の待ちは、最後のレビュー（見た head）ごとに別の出来事にする。人が頼んだ直し（判断のカードの「別案にする」「直してほしい」・最終 PR への指示）の後にもう一度 `reviewing` になれば、直した head の確認の待ちとして知らせ直す。直しで head が変わらなくても、直させたカードは答え待ちに戻るので知らせ直す
  - 1 つの epic（Mac）について同じ周に見つけた出来事は、1 通にまとめる（質問が 5 件出ても 1 通）
  - どの端末にも届かず、送り直せる失敗（APNs の障害・上限・つながらない・鍵や設定の誤り）だったときは、記録から外し、1・2・5・10・30 分と待ちを延ばして送り直す。宛先が使えないだけ（アプリを消した・古い宛先）なら送り直さない
  - 送る途中で司令塔が落ちたときは送り直さない（二重より取りこぼしを選ぶ。記録してから送り終えるまでの数秒の間だけ）
  - 終わった出来事の記録は、7 日たってから消す（GitHub の障害で一覧が空に見えた周に、記録を消して知らせ直さないため）
- 送る宛先は、`devices/` のうち、確かめた公開鍵の一覧にある（登録済みで取り消していない）端末だけ。なくした端末の鍵を取り消せば、その端末には送らない
- クライアント（iOS・macOS）は、状態リポジトリにつながってこの端末の鍵が登録された後に、一度だけ通知の許可を求める（`AskHub/Push/PushRegistration.swift`）
  - 鍵の登録は、起動のときと、設定を開いたとき（「登録を確かめ直す」を含む）に確かめる。登録の前に許可を求めないのは、登録されていない端末には司令塔が送らないため
  - 許可されていれば、起動のたびに APNs に登録し、届いたデバイストークンを `devices/<この端末の鍵の id>.json` に書く。トークン・APNs の環境・端末の種類が同じなら書かない（変わったら書き直す）
  - APNs の環境は、entitlement の `aps-environment` と同じビルド設定 `APS_ENVIRONMENT`（`Configs/Debug.xcconfig` は `development`、`Release.xcconfig` は `production`）を Info.plist の `AskHubAPNsEnvironment` に入れて読む
  - 断られたら、設定の「通知」に、通知が届かないことと、設定アプリ（Mac はシステム設定）の通知の画面を開くボタンを出す
  - デモのデータ（UI テスト・撮影を含む）と、アプリの中で動く単体テストでは、許可を求めず宛先も書かない
  - macOS の push の entitlement は provisioning profile が要り、profile の無いアドホック署名ではビルドが止まる。アドホック署名（CI・ワーカー・スクショ・archive。`CODE_SIGN_STYLE=Manual`）では付けず、自動の署名のときだけ付ける（`Configs/Project.xcconfig` の `ASKHUB_MACOS_ENTITLEMENTS_*`）。アドホック署名の Mac のアプリは通知を受け取れない
  - iOS の配布（TestFlight・App Store）の archive は署名せずに作るので、`Tools/embed_archive_entitlements.py embed` で entitlement をアドホック署名で埋め込んでから Export する（`_archive.yml`）。
    Export は archive の署名の entitlement だけを引き継ぐので、埋め込まないと TestFlight の版に `aps-environment` が入らず、APNs への登録が失敗する。
    Export の後に IPA に残ったかを確かめ（`check`）、落ちていれば App Store Connect に上げずに止める
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
  | 止めないもの | 実機確認 | まとめて 1 日に数回 |

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

- CI でビルドし、Developer ID で署名したものを配る
- 入れ方は、プログラムのファイルをホームフォルダの下に置き、`setup`（想定のコマンド）で値を登録するだけ。管理者の権限は使わない
- 常駐できる Mac では、ログイン中のセッションの LaunchAgent として登録する（ssh のセッションからは Keychain を読めないため）。常駐できない Mac では、ターミナルで `askhub-worker run` を流したままにする（下の「ワーカーの入れ方」）
- `claude` は 1 か所にだけ入れ、版を固定する。段階 0 で、常時オンの Mac に 2 か所・別の版で入っていたことが分かった
  - 司令塔とワーカーは、設定の `claude`（`setup --claude` で渡した絶対パス）だけを使い、`DISABLE_AUTOUPDATER=1` を渡して自分で更新させない
  - 生きている印を書くたび（10 分ごと）に `claude --version` を測り直して `versions.claude` に書く。人が入れ替えたら、読み込み直さなくても次の印で分かる
  - クライアントは、Claude Code の版が司令塔と違う Mac を、Mac の画面と「あなたの番」（時間のあるときに）に出す。オフラインの Mac は、戻ってから出す
  - 版をそろえるには、司令塔と同じ版の `claude` を、その Mac の設定の `claude` の場所に入れる（次の Claude の呼び出しから使う）
- 生きている印に版を書く。司令塔とワーカーの版が合わないときは、ジョブを受けずに知らせる
- 更新の手順（常時オンの Mac は遠隔で、ほかの Mac は手で）を、切り替えの前に決める
- 作業ファイルは TCC の保護の対象の場所（デスクトップ・書類など）に置かない。ワーカー専用のフォルダを使う
  - 設定と Claude のフォルダは `~/Library/Application Support/AskHub/<役割>/`
  - 対象のリポジトリの写し・epic の作業場所・DerivedData・ビルドの一時フォルダは、パスに空白の無い `~/Library/Developer/AskHub/<役割>/`（`work`・`builds`・`builds-tmp`）。パスの空白を扱えないビルドのプラグインやスクリプトがあるため（2026-11-09、prime-pick-ios の LicenseList のプラグインが `SourcePackages not found` で止まった）
  - 移す前の版で作った `~/Library/Application Support/AskHub/<役割>/` の `work`・`builds`・`builds-tmp` は、移した後は使わず、epic の片付けでも消えない。動いている epic は、次のジョブで作業ブランチ（リモート）から新しい場所に取り出し直す
  - 前の場所は、動いている epic が無いとき（実装の途中の質問を待っている epic も無いとき）に手で消す。消すのは `work`・`builds`・`builds-tmp` の 3 つだけで、同じフォルダの `config.json` と `claude/` は今も使うので残す
    - 消す前に、epic の作業場所（`work/epics/<epic>/repository/<リポジトリ名>`。`work/epics/<epic>/` は git の作業場所ではない）に、push していない変更や stash が残っていないかを `git -C <作業場所> status`・`git -C <作業場所> log HEAD --not --remotes`・`git -C <作業場所> stash list` で確かめる。epic の作業ブランチには upstream が無いので、`git log @{u}..` は使えない
    - 残っていれば作業ブランチに push してから消す。ただし、場所を移す前に止まった試行の、コミットしていない変更が残っていることがある。新しい場所でやり直したタスクのコミットと見比べて、中身が入っていれば push は要らない（2026-11-09、prime-pick-ios）
    - 消すのはゴミ箱に入れる（取り消せるように）。ssh 越しでは Finder を使えないので、`~/.Trash/<名前>/` に `mv` する（Finder の「戻す」は使えないので、戻すときも `mv`）。ゴミ箱に入れただけでは空き容量は増えず、ゴミ箱を空にしたとき（Finder の「30 日後にゴミ箱から削除」が有効なら 30 日後）に空く

### 司令塔の入れ方（段階 2）

常時オンの Mac で、ログインしているユーザーが端末から流す（ssh からは Keychain を読めない）。

1. `askhub-commander` を置く（ホームフォルダの下。管理者の権限は使わない）
2. `askhub-commander setup --state-repo <owner/repo> --mac <名前> --claude <claude の絶対パス> --first-key <最初の鍵の id> --key-account <GitHub のアカウント> [--github-owner <対象のリポジトリの持ち主> ...]`
   - 設定（秘密を含まない）を `~/Library/Application Support/AskHub/commander/config.json` に書く
   - GitHub のトークン（持ち主ごと）と Claude の setup-token は、端末で伏せて入れ、Keychain（サービス `jp.shilokuma.AskHub.commander`）だけに置く。引数や標準入力では受け取らない。Claude の欄に API キー（`sk-ant-api03-`）が貼られたら断る
   - GitHub のトークンは、持ち主（organization・個人）ごとの fine-grained token にする（下の「GitHub のトークン（持ち主ごと）」）。状態リポジトリの持ち主の分と、`--github-owner` で並べた持ち主の分を順に聞く。状態リポジトリの読み書き（人の意図・質問・ジョブ・生きている印）は状態リポジトリの持ち主のトークン、対象のリポジトリの写し（clone・fetch）と Discussion の写し（作る・直す。[flows.md](flows.md) の「Discussion の写し」）は、そのリポジトリの持ち主のトークンを使う
   - 持ち主のトークンが無いリポジトリは、写しと Discussion の写しが認証の失敗になり、司令塔のログと試行に理由が出る。後から持ち主を足すときは `askhub-commander token <持ち主>` で入れる（設定にも足す。常駐を読み込み直さなくても、次の要求から使う）
   - 段階 3 で、1 つのトークンから持ち主ごとのトークンに変えた。前の 1 つのトークンからは移さないので、段階 2 で入れた常時オンの Mac は `setup` を流し直す（設定の形も変わったので、流し直すまで `run` は止まる。APNs の設定は残す）。前のトークンは Keychain から消す
   - 公開鍵の記録の最初の鍵を固定する（後から別の鍵には変えられない）
   - 対象のリポジトリは、Discussions を有効にし、カテゴリ「Ideas」（有効にすると GitHub が作る既定のカテゴリ）を残しておく。無いあいだは Discussion の写しを書かず、司令塔のログに理由を出す（依頼から開始までの流れは止まらない）
3. `askhub-commander launch-agent` で LaunchAgent の定義を書き、出てくる `launchctl bootstrap` のコマンドで登録する（ログは `~/Library/Logs/AskHub/commander.log`）
4. `askhub-commander check` で、設定と Keychain の様子・トークンの期限（値は出さない）を確かめる
5. 状態リポジトリに見張りを入れる（上の「司令塔の見張り」の「正本と入れ方」）

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

### ワーカーの入れ方（段階 3）

開始のときに人が選ぶ Mac に入れる。ログインしているユーザーが端末から流す（ssh からは Keychain を読めない）。

1. `askhub-worker` を置く（ホームフォルダの下。管理者の権限は使わない）
2. `askhub-worker setup --state-repo <owner/repo> --mac <名前> --kind resident|manual --claude <claude の絶対パス> --first-key <最初の鍵の id> --key-account <GitHub のアカウント> [--github-owner <対象のリポジトリの持ち主> ...]`
   - `--kind` は、LaunchAgent で常駐できる Mac なら `resident`、できない Mac（会社の決まりで launchd に常駐させられない社用の MacBook など）なら `manual`
   - 同時の上限は `--claude-capacity`（既定 2）と `--build-capacity`（既定 1）で変えられる
   - 常時オンの Mac を epic の Mac にも使うときは、司令塔の `setup` でも `--build-capacity 1` を付ける（司令塔の既定は 0 で、ビルドの要る実装のジョブを引き受けない）
   - 設定（秘密を含まない）を `~/Library/Application Support/AskHub/worker/config.json` に書き、トークンは司令塔と同じく端末で伏せて入れ、Keychain（サービス `jp.shilokuma.AskHub.worker`。司令塔とは分ける）だけに置く。最初の鍵は司令塔と同じものを固定する（ジョブの元になった人の意図の署名を、ワーカーも確かめる）
3. 起動する
   - 常駐できる Mac: `askhub-worker launch-agent` で LaunchAgent の定義を書き、出てくる `launchctl bootstrap` のコマンドで登録する（ログは `~/Library/Logs/AskHub/worker.log`）
   - 常駐できない Mac: ターミナルで `askhub-worker run` を流したままにする（ログはそのターミナルに出る）。再起動・ログアウトで止まり、クライアントに「オフライン」と出るので、もう一度流せば続きから再開する
4. `askhub-worker check` で、設定と Keychain の様子・トークンの期限（値は出さない）を確かめる

- `run` は、この Mac が受け持つ epic（開始のときに選ばれた epic）のジョブを 60 秒ごとに読み、自分宛ての `assigned` のジョブを同時の上限の中で引き受けて試行を書く。生きている印（`macs/<mac>.json`）は 10 分ごとに書く。人の意図の処理とジョブの状態の更新はしない（司令塔の仕事）
- 引き受けたジョブは、元になった人の意図の署名を確かめてから実行する。確かめられなければ実行せず、想定外の失敗として人に渡す
- 作業場所の用意（`prepareWorkspace`）では、ワーカー専用のフォルダの clone から epic の作業場所（`work/epics/<epic>/`。ジョブを超えて残す）に作業ブランチ `askhub/<epic の id>` を取り出し、リモートに無ければ `origin/develop` から作って push する（force push しない）。リモートにあれば作り直さずに使う。作業ブランチの名前と先頭のコミットは試行の `outputs` に書く（`epic.json` は司令塔が書く）
- git の credential helper はワーカー自身（`askhub-worker git-credential`）。トークンの選び方は司令塔と同じ

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

### トークンの期限

GitHub のトークン（持ち主ごと）と Claude の setup-token には期限がある。切れると、その Mac の仕事（状態リポジトリのトークンなら生きている印も）が止まるので、司令塔とワーカーが期限を生きている印の自己診断に書き（値は書かない。[protocol.md](protocol.md) の「macs/<mac>.json」）、クライアントで知らせる。

- GitHub のトークン: 生きている印を書くたび（10 分ごと）に、持ち主ごとのトークンで GitHub の `/rate_limit`（REST の上限に数えられない）を呼び、応答の見出し `github-authentication-token-expiration`（`2027-10-23 12:25:03 UTC` の形）から期限を読む
  - 見出しが無いのは、期限の無いトークン。401 が返ったら使えない（前に読んだ期限を過ぎていれば期限切れ）。つながらないときは前に読んだ期限のまま
- Claude の setup-token: 作った日から 1 年使える。`setup`・`claude-token` で新しい値を入れた日を `~/Library/Application Support/AskHub/<役割>/claude-token.json` に記録し（日付だけ）、その 1 年後を期限とする
  - 記録を始める前に入れた setup-token は、期限が分からない（クライアントに「期限は分かりません」と出る）。`claude setup-token` で作り直して `claude-token` で入れると記録される
- クライアントは、Mac の画面にトークンごとの残り日数を出す
  - 期限まで 14 日を切ったら、「あなたの番」（時間のあるときに）に入れ直すコマンドを出す
  - 期限が切れた・使えないトークンは、進行を止めるものとして「止まっています」と出す（状態リポジトリのトークンが切れた Mac は印を書けずにオフラインになるが、オフラインが 7 日を超えるまでは出す）
- 入れ直し（その Mac の端末で流す。常時オンの Mac は `askhub-commander`、ほかの Mac は `askhub-worker`）

  | トークン | 作り直し | 入れ直すコマンド |
  | --- | --- | --- |
  | GitHub（持ち主ごと） | 上の「GitHub のトークン（持ち主ごと）」の 1〜5（Regenerate でもよい） | `token <持ち主>`。常駐を読み込み直さなくても、次の要求から使う |
  | Claude の setup-token | 人の Mac で `claude setup-token` | `claude-token`。常駐のループは起動したときの値を使うので、読み込み直す（`launchctl kickstart -k gui/$(id -u)/jp.shilokuma.askhub.commander`、ワーカーは `…askhub.worker`。ターミナルで流しているワーカーは流し直す） |

- `check` で、持ち主ごとの GitHub のトークンと Claude の setup-token の期限を確かめられる

### 非常口（`askhub`）

クライアントが壊れても人の意図を出せるように、Mac の端末から署名して送るコマンド。鍵は Secure Enclave（無ければソフトウェアの鍵）に作り、GitHub のトークンと一緒にその Mac の Keychain（サービス `jp.shilokuma.AskHub.cli`。司令塔とは分ける）だけに置く。段階 2 の試運転では、クライアントのつなぎ込みの前に、これで依頼から開始の待ちまでを通しで動かす。

1. `askhub setup --state-repo <owner/repo>`: 設定を書き、GitHub のトークン（状態リポジトリを読み書きできるもの）を端末で伏せて入れ、署名の鍵を作る
2. `askhub key register-first --account <GitHub のアカウント> --label <名前>`: 公開鍵の記録が空のときに、この鍵を最初の鍵（`keys/1.json`）として登録する。出てくる鍵の id を、司令塔の `setup --first-key` に渡す
   - ほかの端末の鍵は `askhub key add --public-key <base64url> --account … --label …`、取り消しは `askhub key revoke <鍵の id>`
3. `askhub add-repository --repo <owner/repo>` → `askhub configure-repository --repo … --file <build.json>`（下の「ビルドの設定の入れ方」。開始の前に要る）→ `askhub request --repo … --title … --body …`
4. `askhub status` で epic・答える質問（id と版と選択肢）・ゴール・送った意図の処理の結果を見て、`answer`・`clarify`・`decide-split`・`revise-goal`・`start` で進める
5. 要らなくなった依頼は、開始する前なら `askhub abandon --repo … --epic …` で取り下げる。開始した後の一時停止・再開・引き継ぎは、上の「Mac の一時停止・再開・引き継ぎ」
6. 人の対応待ちのジョブ（認証切れ・想定外の失敗など）は、`askhub status` に失敗の理由と、`retry`（やり直す）・`give-up`（やめる）に渡す引数（ジョブの id と試行の番号）が出る。原因を直してから `retry` を送る

## 容量

- ワーカーは、自分で作ったもの（worktree・Simulator・DerivedData）を、最終 PR のマージ後に自動で片付ける
- 片付け（`cleanUp`）は epic の Mac だけで動くので、司令塔とワーカーは、生きている印を書いた後の見回りで、終わった（マージした・やめた）epic の、自分のフォルダに残った作業場所・手元のブランチ・DerivedData を消す。常時オンの Mac で最終 PR を直した epic、片付けを見張る間（マージから 7 日）に epic の Mac が戻らなかった epic、開始した後にやめた epic のものが当たる
  - 消すのは、状態リポジトリで終わったと確かめられ、終わってから 1 日たった epic のものだけ（終わった直後に、人が残りものを確かめられるよう少し残す。読めない・見つからない epic のものは残す）
  - ジョブが作業場所を使っている epic は、待たずに次の見回りに回す。Simulator の枠は epic をまたいで使い回すので触れない
- Simulator は、ワーカーの中の枠ごとに決まった名前（`askhub-` で始まる）で作り、使い回す。動いているループに属さないものは、定期的な見回りで消す
- clone 本体は、最後に使ってから 7 日で消す。空き容量が少なければ早めに消す
- 常時オンの Mac は、段階 0 の時点で空きが約 15 GB しかなく、今の仕組みのループが作った Simulator（約 34 GB）と DerivedData（約 21 GB）が場所を取っている。切り替えの準備で、今の仕組みを止めた後に片付ける
- ワーカーが作っていないもの（手で作った clone・Simulator）は、クライアントに「片付けの候補」として出し、人が選ぶ。探すのは、人がクライアントで「探す」を押したときだけ。消す前に、未コミット・未 push・stash が無いかを確かめる
- 各 Mac の空き容量を生きている印に書き、クライアントに出す。空きが一定以下なら、その Mac は新しいループを受けずに知らせる

## Claude の利用上限

- 利用上限は契約ごとに来る（[architecture.md](architecture.md)）。上限に達したら、解除の時刻まで待って再開する
- 無人の実行の使用率（5 時間・週の枠の何 % か）を読む公式の手段は無い。クライアントに出せるのは、ワーカー自身の使用量の見積もりと、上限に達したときの解除の時刻だけ（使用率の表示は切り替えの後に回す）
- 1 回の呼び出しの暴走は、時間の上限と `--max-budget-usd` で止める

## 対象のリポジトリ

- 機能の依頼でリポジトリを選ぶときは、対象のリポジトリだけを出す
- 「対象に加える」でリポジトリを選ぶときは、まだ対象になっていないものだけを出す
- どちらも検索できるようにする
- 対象に加えるときは、GitHub 側の準備（Discussions・共通リポジトリのワークフローを呼ぶファイルを入れる PR）と、設定を状態リポジトリに書く。ブランチ保護は人が押したときだけ設定する
- リポジトリの新規作成は、「テンプレートからの複製」と「対象に加える」と同じ手順の組み合わせにして、できあがるものをそろえる

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
   - `xcode` の値は `xcodebuild` の引数になる。`project` はリポジトリの直下からの相対パス。`destinations` は並べた順に流す（macOS は `{ "platform": "macOS" }`。`osVersion` を省くと、使う Xcode の SDK と同じか古いランタイムのうち最新）。`testLight`（子 PR の前）・`testFull`（最終 PR の前。UI テストを含む）は、省くと全部のテスト
   - `childChecks`・`finalChecks` は、待つチェックの名前（1 つ以上）。PR の画面のチェックの表示と同じで、再利用ワークフローのジョブは `build / build` の形になる。develop の最近のコミットのチェックの名前は `gh api repos/<owner>/<repo>/commits/develop/check-runs --jq '.check_runs[].name'` で見られる
   - `trustedReviewers` は、指摘を Claude に渡してよいレビューの書き手（無ければ空。CodeRabbit は最終 PR でだけ待つ）
   - `screenshots` は、判断のカードのスクショの撮り方（無ければ撮らない。下の「判断のカードのスクショの入れ方」）
2. 非常口から送る: `askhub configure-repository --repo <owner/repo> --file build.json`。送る前に、司令塔と同じ決まり（`-` で始まる値・リポジトリの外を指すパス・知らない欄・チェックが空）で確かめ、合わなければ送らない
3. `askhub status` で、送った意図が受け付けられたか（断られたら理由）を見る。送るたびに `build` をまるごと置き換える

- クライアントでの入れ方は、まだ無い（[protocol.md](protocol.md) の「決めていないこと」）

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
- 一覧の画面の `id` は変えない（変えると Before と比べられなくなる）

### 既存のリポジトリを移すとき

今の仕組みで管理しているリポジトリは、作りがそろっていない（段階 0 の後の調査）。「対象に加える」で次も扱う。

- **ビルドの設定**: プラットフォーム、テストの行き先（Simulator の種類）、プロジェクトの作り方（XcodeGen なら生成してから）、スキームをリポジトリごとに持つ。ワーカーはこれでビルドとテストを流す（上の「ビルドの設定の入れ方」。XcodeGen などで生成してからビルドするリポジトリは、まだ扱えない）
- **CI のチェックの名前**: 子 PR で待つ必須のチェックの名前はリポジトリごとに違うので、決め打ちにしない（ルールセットか、develop の最後の回から読んで、ビルドの設定の `childChecks`・`finalChecks` に入れる）
- **共通リポジトリの前の期間**: 共通リポジトリ（段階 5）ができるまでは、各リポジトリの今のワークフローを入れ替えずに使う
- **今の仕組みの残りもの**: ラベル・状態用の Issue・ループの中継のスクリプト・CLAUDE.md のループの節を外す PR を、移すときの手順に入れる
- **移管・改名**: 状態リポジトリのパスは owner/name なので、リポジトリの移管・改名に追って、状態のファイルを移す
- **App Store Connect の鍵**: 今は organization ごとの Secrets に置いてある。段階 5 で、App Store Connect の状態をどのリポジトリの Actions で読むかを決める
- **Apple 以外の部品**: backend などを持つリポジトリは、ワーカーの検証に足すか、その部分の変更を人に回すかを、移すときに決める

## 共通リポジトリとテンプレートの配布

- CI・リリースのワークフローと道具は、共通リポジトリ（public）から配る。各リポジトリには、GitHub Actions の再利用ワークフローを呼ぶ薄いファイルと、小さな設定ファイル（スキーム・プラットフォームなど）だけを置く
- 呼ぶ版は固定したコミット（または保護したタグ）にし、クライアントから上げる。新しい版は 1 つのリポジトリで試してから広げる。どのリポジトリがどの版かをクライアントに出す
- テンプレートに残すのは、アプリの骨組み（プロジェクト・画面の雛形）だけにする
- 切り替えのときに、今あるリポジトリにも「対象に加える」と同じ手順を流し、ワークフローと設定をそろえる
- プロジェクトを設定ファイルから作る道具（XcodeGen を候補にする）に移し、Widget や App Clip のターゲットの追加もループでできるようにする。テンプレートの配布の段階で、ターゲットを足す頻度を見て決め直す
- 各リポジトリの CLAUDE.md は、「全員向けの事実」と「人のセッション向けの手順」に分ける。ワーカーの Claude に渡す規則は、ワーカーの中に持つ
  - 全員向けの事実は `## 全員向けの事実` の見出しの下に書く。見出しがあればその節だけを、無ければ CLAUDE.md 全体を Claude に渡す
