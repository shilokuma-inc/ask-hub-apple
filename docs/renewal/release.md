# リリース

リリースの仕組みは、共通リポジトリから全リポジトリに配る（[operations.md](operations.md)）。今の仕組みのリリースのワークフロー（Release/Prepare・Notes・Sync・Finish）は ask-hub-apple にしか無く、一度も実行されていないので、流れから作り直す。今の仕組みのものは #1087 で外した（[plan.md](plan.md) の「段階 5 の順」）。

## 流れ

| 順 | 段階 | するのは | 中身 |
| --- | --- | --- | --- |
| 1 | リリースを始める | 人 | バージョンを選ぶ（既定は次のマイナー） |
| 2 | 準備 | 自動 | release ブランチを作り、develop のバージョンを次に上げ（司令塔の PR）、最新情報の下書きを作り、Upload する |
| 3 | 下書きとビルドの確認 | 人 | 最新情報・スクショの差分・その版の未確認の実機確認を確かめる |
| 4 | 審査に出す | 人がボタンを押す | 司令塔が App Store Connect の API で提出する（下の「App Store Connect の状態と操作」） |
| 5 | 審査の状態の見張り | 自動 | 司令塔が審査中・承認・リジェクトを読み、クライアントに出す |
| 6 | 配信 | 既定は自動 | 承認されたら配信する（審査に出すときに人が選んだ配信の方式。リリースごとに変えられる） |
| 7 | 後作業 | 自動 | 司令塔が配信を見つけ、main と develop への取り込み（司令塔の PR）・タグ・GitHub Release を行う |

### バージョン

- release ブランチを作ったら、develop の `MARKETING_VERSION` をすぐ次のバージョン（既定は次のマイナー）に上げる。上げるコミットは、司令塔が PR にして、CI が通ったら自動でマージする（develop は保護されているので直接 push しない）
  - 審査に出すバージョンのビルドは、release ブランチからしか上がらなくなる。develop のビルドと取り違えない
  - develop の Upload が、配信済みのバージョンで失敗することもなくなる
  - 大きく上げたいとき（2.0.0 など）は、次のリリースを始めるときに選び直す
- 後作業で release を develop に取り込むときは、develop のバージョンを上書きしない
- 初回だけ同じバージョンを許す今の決まりは要らなくなる

### 審査に出す

- 提出は App Store Connect の API（Review Submissions）で行う（下の「リリースを始めてから配信まで」）
- 輸出コンプライアンスの質問は、テンプレートの Info.plist に `ITSAppUsesNonExemptEncryption` を入れて、毎回聞かれないようにする（独自の暗号を使わないアプリ）。答えていないビルドは、司令塔が答えずに人が直す問題にする（法令の申告なので、機械が代わりに答えない）

### 配信

- 配信の方式の既定は「承認後すぐ自動」。リリースごとに、審査に出すときに「手動」「日時を指定」に変えられる
- 手動のときは、承認された（Pending Developer Release の）版に「配信する」を出す。配信は App Store Connect の API（`appStoreVersionReleaseRequests`）で行い、取り消せないので確認を挟む

### リリース中の直し

- TestFlight で見つかった不具合やリジェクトのために、「このリリースを直す」依頼を出せる。ループは release ブランチ宛てに直し、後作業で develop にも取り込む
- 実機確認で「問題あり」を付けるときに、「このリリースで直す」か「次のリリースで直す」かを選べる

2026-11-22 に作った形（#1207）:

- 依頼（`request`）に直すリリースの版（`release`）を持たせる。司令塔は、AskHub で始めた終わっていないリリースで、release ブランチを作ったものだけ受け付け、epic の `release` に写す（[protocol.md](protocol.md) の「epic.json」）。質問・ゴールの確認・開始の流れは、ふだんの依頼と同じ
- epic の作業ブランチは `release/<版>` の先頭から作り、子 PR は作業ブランチに、最終 PR は `release/<版>` に向ける。開始前の Claude のジョブ（質問づくり・着手前の確認など）も、`release/<版>` の写しを読む。CI は release ブランチへの PR でも、ふだんと同じチェック（`childChecks`・`finalChecks`）を待つ（ルールセット `askhub-protect` も `release/**/*` を守る）。base とのコンフリクトの直しは `release/<版>` を取り込む
- 最終 PR をマージすると、release ブランチへの push で Upload が動き、準備の見回り（ビルドを待つ）が新しいビルドを拾って `revision` を上げる。審査に出した後は、出したビルドを変えない（出し直すなら取り下げてから）
- What's New の下書きは release ブランチを作ったときの先頭までで書くので、後から release ブランチに入れた直しは入らない（人が審査に出すシートで直せる）。GitHub Release のリリース文は配信したコミットまでの変更で書くので、入る
- 配信した後の取り込み（release → develop・main）は今までの後作業のまま。直すリリースが終わった（配信した・やめた）後は、最終 PR をマージせずに人へ渡す（取り込みは配信したときの 1 回だけなので、その後の直しは develop に戻らない。次のリリースで直すなら epic をやめて依頼し直す）
- クライアント: リリースの画面の「このリリースを直す…」で、直す先の版つきの依頼のシートを開く。実機確認の「問題あり」は、リポジトリにリリースが進行中のときだけ「このリリースで直す」「次のリリースで直す」を選べる。既定は、確かめた epic が進行中のリリースの release ブランチを作る前にマージされていれば「このリリースで直す」、後なら「次のリリースで直す」（2026-11-22 にユーザーが決めた）

### リジェクト

1. 定期実行がリジェクトを見つけ、クライアントに出して通知する
2. 人が App Store Connect のアプリで理由を見て、クライアントに貼る（スクショでもよい）。公開の API では、審査とのやり取りの本文は取れない見込み
3. Claude が理由を読み、「コードを直す」「メタデータだけ直す」「返信だけで済む」のどれかを示す。最後に選ぶのは人
   - コードを直す: 「このリリースを直す」依頼にして、いつもの流れに乗せる
   - メタデータだけ直す: ビルドは作り直さず、メタデータを直して反映する
   - 返信だけで済む: Claude が返信の下書きを作り、人が App Store Connect に貼る
4. 直ったら、クライアントで「審査に出し直す」を押す

2026-11-22 に作った形（#1208）:

- 理由を貼る（`reportRejection`）: AskHub で出して断られた版の画面に「リジェクト」の欄を出し、審査の文と画面の画像を貼る。画像は依頼の添付と同じく意図より先に状態リポジトリに置く。直し方を選ぶ前なら貼り直せる（前の案は捨てて書き直す）。
  手で審査に出した版（`origin` が `appStoreConnect`）は今は扱わない（AskHub から出し直せないため。理由は App Store Connect で確かめる）
- 直し方の案: 見回りが、常時オンの Mac の Claude（読むだけ）に、release ブランチの今の先頭の写し・貼った文・画像（一時フォルダに置いて `--add-dir` で読ませる）・断られた版の今の掲載文と App Review の情報・審査に出した What's New・同じ版の前のリジェクトを渡し、
  勧める直し方（`code`・`metadata`・`reply`）・理由の要約・直し方の手順・「このリリースを直す」依頼の下書き・掲載文 / What's New / App Review の情報の直す案・App Review への返信の下書きを書かせる（書けたものはすべて持ち、人がどれを選んでも使えるようにする）。
  待てば書ける失敗（Claude の利用上限・障害）は次の見回りでやり直し、書けない失敗は理由を記録に書いて、人に理由を読んで選んでもらう
- 直し方を選ぶ（`resolveRejection`）: 審査に出した中身（`submit`）を消して、出し直すシートの元を作る（What's New は前に確かめた文、掲載文と App Review の情報は断られた版の今の文。メタデータを直すなら Claude の案を「変える」の候補にする）
  - コードを直す: クライアントが、Claude の下書き（題・本文）と貼った画像を付けた「このリリースを直す」依頼のシートを開き、人が直して送る（2026-11-22 にユーザーが決めた）。直しの epic をマージして release ブランチから新しいビルドが上がるまで、出し直す準備はそろわない
  - メタデータだけ直す: 出し直すシートで、Claude の案の欄を確かめて「変える」を選ぶ。API で直せないもの（スクショ・年齢制限など）は案の手順に書かれ、人が App Store Connect で直す
  - 返信だけで済む: 返信の下書きをコピーして App Store Connect の App Review への返信に貼る。返した後に出し直す（App Review が返信だけで通したら、見張りが審査の状態の変化を読む）
- 審査に出し直す: いつもの「審査に出す」（`submitForReview`）と同じシートで出す。司令塔は、断られた版（Rejected・Metadata Rejected などは編集できる版）を直し、App Store Connect に断られたままの提出（`UNRESOLVED_ISSUES`）にこの版が入っていれば、
  断られた項目（`REJECTED` の reviewSubmissionItem）を直したことにして（`resolved: true`）から、同じ提出を出し直す（`submitted: true`）。出し直しの手順は Apple の文書に無い（2026-11-22 に確かめた）ので、断られたら人が直す問題にし、
  App Store Connect で「審査に出し直す」を押してもらう（押せば、次の見回りで審査を待っているとして読む）
- 通知: [operations.md](operations.md) の「通知」のリジェクト

### hotfix（配信中の版だけを直す）

- 配信中の版のタグから `release/x.y.(z+1)` を作る。develop には触れない
- 後作業で main と develop の両方に取り込む
- App Store Connect の編集できるバージョンはプラットフォームごとに 1 つなので、通常のリリースが進行中のときは hotfix を優先する。進行中の版をいったん取り下げ、hotfix を配信してから、進行中の版の準備をやり直す。取り下げの前にクライアントで確認を挟む（取り下げとやり直しを API でどこまでできるかは要確認）

2026-11-22 に作った形（#1209）:

- 始める: 配信した版の画面（最も新しい配信した版だけ）の「hotfix を始める…」。版は配信した版の次のパッチ（x.y.(z+1)）。リリースを始める意図（`startRelease`）に `hotfix` を付けて送る
- release ブランチは配信中の版のタグ（`v<版>`）から作り、release ブランチの `MARKETING_VERSION` を hotfix の版に上げる PR（`askhub/hotfix-version-<版>`）を出して、チェックが通ったらマージする（release ブランチもルールセットで PR 必須のため）。develop には触れない
- 直すことは「このリリースを直す」依頼（#1207）で release ブランチに入れる。What's New と掲載文の案は、直しを入れたビルドが上がってから release ブランチの今の先頭で書き、ビルドが変わるたびに What's New を書き直す（人が審査に出すシートで確かめる）
- 進行中のリリースがあるとき（2026-11-22 にユーザーが決めた）: 確認のダイアログで「一時停止して hotfix を始める」を押すと、意図に一時停止する版（`suspend`）を付けて送る。司令塔は進行中のリリースに一時停止の印（`suspension`）を付け、審査を待っている・審査中なら取り下げを頼む（審査に通った版は API で取り下げられないので断る。配信するか、App Store Connect で取り下げてから）。
  hotfix の版の枠は、進行中のリリースの編集できる版を hotfix の版に付け替えて使う（取り下げが済むまでは待つ）。一時停止の間は、進行中のリリースの準備を進めず、審査にも出せない
- 配信した後: 取り込む先は main・develop・一時停止したリリースの release ブランチ。main 以外へは、release ブランチの版の行を配信中の版に戻したブランチ（`askhub/hotfix-<版>-into-<取り込む先>`）から PR を出す（取り込む先の版を上書きせず、版の行でコンフリクトさせない）。main は release ブランチから取り込む
- 再開: hotfix を一時停止したリリースの release ブランチに取り込み終えたら（hotfix をやめたときも）、そのリリースの release ブランチの今の先頭と時刻を数え直し、ビルド・What's New・掲載文の案・App Store Connect の版の枠を作り直して、「審査に出す」から再開する

## リリースを始めてから配信まで

段階 5 の 3。上の「流れ」の 1〜6 を、人が押す操作（署名した意図）と司令塔の見回り（`ReleaseWatch`）で進める。記録は `submissions/<版>.json`（[protocol.md](protocol.md)）。
2026-11-18 にユーザーが決めたこと: What's New は言語ごとに下書きして人が言語ごとに確かめる・手で審査に出した版も見張って知らせる・審査に出す前（と取り下げた後）にやめられる・配信した後の GitHub Release は審査に出したときの What's New で確認なしに公開する。

### 段取り

| 順 | 段取り | するのは | 中身 |
| --- | --- | --- | --- |
| 1 | リリースを始める | 人（`startRelease`） | リポジトリの画面で版を選ぶ（既定は前に配信した版の次のマイナー）。終わっていないリリースがあれば始められない（App Store Connect の編集できる版はプラットフォームごとに 1 つ） |
| 2 | release ブランチと版の枠 | 司令塔 | develop の先頭から `release/<版>` を Git Data API で作る（ルールセットはブランチの作成を止めない）。作ると Upload が動き、TestFlight に上がる。あわせて、App Store Connect にプラットフォームごとの編集できる版（番号は始めた版、配信の方式は既定の承認後すぐ）を作り、スクショや説明文を先に直せるようにする（2026-11-20 にユーザーが決めた）。同じ番号の編集できる版があればそれを使い、別の番号の編集できる版があれば作らずに人が直す問題にする（hotfix との兼ね合いは段階 5 の 4） |
| 3 | 次の版 | 司令塔 | develop の `MARKETING_VERSION` を次のマイナーに上げる PR（配信の後作業の「次の版」と同じ作り。CI が通ったらマージ）。release ブランチを作ってから出す |
| 4 | What's New の下書きと掲載文の案 | 司令塔（Claude） | 前に配信した版のタグから release ブランチの先頭までの変更で、App Store Connect にある言語ごとに下書きする（言語は配信中の版の掲載文の言語。配信中の版が無ければ初めての版なので下書きしない）。続けて、配信中の版の掲載文（説明文・キーワード・プロモーションテキスト）を同じ変更に合わせて直す案を書く。初めての版は、編集できる版の言語ごとに、アプリの中身から掲載文を一から書く（下の「掲載文」） |
| 5 | ビルドを待つ | 司令塔 | App Store Connect の、その版のビルドのうち、release ブランチを作った後に上げて処理を終えた（`VALID`）最新のものを、プラットフォームごとに記録し、版の枠に選ぶ（配信の方式は送らない）。What's New の下書きができたら、枠の各言語に 1 回だけ書いておく（審査に出すまで公開されない。後で人が App Store Connect で直した文は上書きしない） |
| 6 | 審査に出す | 人（`submitForReview`） | 「あなたの番」で、ビルドと What's New・掲載文（言語ごと・欄ごとに直せる）を確かめ、配信の方式（承認後すぐ・手動・日時を指定）を選んで押す。承認したヘッダーと検索結果の画像があれば、載せるかも選ぶ（[`creative-assets.md`](creative-assets.md)） |
| 7 | App Store Connect に出す | 司令塔 | プラットフォームごとに、編集できる版（ふつうは 2 で作った枠）を直し（版の番号・配信の方式）、ビルドを選び、人が確かめた What's New で上書きし、人が確かめた掲載文の直しを書き、reviewSubmission に版を足して提出する。どれも、する前に今の様子を読み、途中で止まってもやり直せば同じになる |
| 8 | 審査の見張り | 司令塔 | 30 分ごとと、操作の直後に、版の状態（`appVersionState`）を読む。審査中・承認・リジェクトになったら知らせる（リジェクトの対処は段階 5 の 4） |
| 9 | 配信する | 人（`distributeRelease`）か App Store | 配信の方式が手動なら、承認された版に「配信する」を出す。ほかの方式は App Store Connect が配信する |
| 10 | 後作業 | 司令塔 | 配信を見つけたら記録に終わりの印を付け、今までの後作業（`releases/<版>.json`）に渡す。GitHub Release は、審査に出したときの What's New（日本語。無ければ最初の言語）で確認なしに公開する。release ブランチを main と develop に取り込む（下の「release ブランチの取り込み」） |

- 掲載文: 説明文・キーワード・プロモーションテキストは、App Store Connect が前の版の文を新しい版に写すので、変えるときだけ直す（2026-11-20 にユーザーが決めた）。
  Claude が、配信中の版の掲載文と変更（コミット・epic）をもとに、使う人に見える新しい機能があって今の文が食い違う・触れていないときだけ、言語ごとに直す案を書く（今の文を元に必要な所だけ。変えない欄は書かない）。変えないときは「変えない」とその理由を残す。
  人は審査に出すシートで、言語ごとに開いて欄ごとに「変える」を選び、案（案の無い欄は今の文）を直す。司令塔は人が変えた欄だけを `appStoreVersionLocalizations` に書き、ほかの欄は App Store Connect の文を残す（App Store Connect で直した文を上書きしない）。
  長さはキーワードが 100 バイト（Apple の文書がバイトで書いている。多バイト文字の数え方は書かれていないので、多めに数える UTF-8 で数える）、説明文が 4,000 文字、プロモーションテキストが 170 文字。初めての版（配信中の版が無い）は、版の枠の今の文（新しいアプリでは空）を元に、Claude が README・画面のコード・文言・`docs/app-store/metadata/<言語>.md`（あれば）から、言語ごとに説明文とキーワード（とプロモーションテキスト）を一から書く。どの言語も説明文とキーワードがそろわない案は使わない。今の文は、プラットフォームごとの版のすべてに同じ文が入っている欄だけとみなし（片方が空・文が違う欄は案で書き、人が確かめた文をすべてのプラットフォームの版に書く）、版の枠ができるまでは待つ。この仕組みの前に始めた記録（版の枠を作らない）で編集できる版が無ければ、人が App Store Connect で版を作る問題にする（2026-11-20 にユーザーが決めた。#1166）。審査に出すときは、書く前に、提出先の版ごとに、人の直しを当てた掲載文でどの言語にも説明文とキーワードがそろうかを確かめ、そろわなければ書かずに止めて人の番にする（後から足したプラットフォームの版や、人が「変える」を外した欄が空のまま残らないように）。
  プロモーションテキストは審査なしで変えられるので、配信中の版にいつでも反映できる（同じ日にユーザーが決めた。#1160）。司令塔が配信の見回り（30 分ごと）で配信中の版の今の文を読んで配信の記録（`releases/<版>.json` の `promotionalText`）に書き、
  人が配信した版の画面で言語ごとに直して「反映する」を押す（`updatePromotionalText`）と、司令塔が配信中の版（プラットフォームごと）の `promotionalText` に書く。App Store Connect が断ったら、理由を記録に書いて画面に出す
- App Review の情報: 審査メモ・デモアカウントの要否と名前は、掲載文の案と同じ Claude の下書きで、審査する人が新しい機能を試すのに手順や説明が要るとき（見つけにくい機能・ログイン・課金・権限など）だけ直す案を書く（#1164）。
  審査に出すシートには、案があるときだけ「App Review の情報」の欄を出し（変わったときだけ人が直す）、司令塔は人が確かめた欄だけを審査に出す版の `appStoreReviewDetail` に書く（無ければ作る）。
  デモアカウントのパスワードと連絡先は読まない・書かない・状態リポジトリに置かない。パスワードは人が App Store Connect で入れる（2026-11-20 にユーザーが決めた）
- release ブランチの取り込み: 取り込む先（base の develop と main）ごとに、release ブランチが進んでいれば（`compare`）司令塔の PR を出し、チェックが通ったらマージコミットでマージする。進んでいなければ取り込まない（直しの無いリリースの develop）。main が無ければ release ブランチの先頭から作る。release ブランチで版を変えていないので、develop の版は上書きされない。コンフリクト・チェックの失敗・閉じられた PR は人が直す問題にする
- 取り下げ（`withdrawSubmission`）: 審査を待っている・審査中なら、reviewSubmission を取り消す（`canceled`）。取り下げた後は、ビルドや What's New を直して出し直せる
- やめる（`abandonRelease`）: 審査に出していない・取り下げた・断られた版なら、記録に終わりの印を付け、リリースを始めたときに作った版の枠のうち、まだ審査に出していないものを `DELETE /v1/appStoreVersions/{id}` で消す。審査に出ている・API で消せない枠は消さずに理由を記録して知らせる（人が App Store Connect で確かめる）。release ブランチ・develop の版を上げる PR には触れない
- 承認された後の取り下げ（Developer Reject）は、API が見つからないので作らない（App Store Connect の Web で行う）
- 手で審査に出した版: 審査を待っている以降の状態の版を見つけ、記録が無ければ `origin` が `appStoreConnect` の記録を作って見張る。手動の配信の版なら「配信する」も出す
- App Store Connect の書き込みは、どれも人の意図を受け付けたときだけ行う。リリースを始める（`startRelease`）で書くのは、審査に出すまで公開されない版の枠（版・ビルドの選択・What's New の下書き）と、撮って比べたスクショの画像のライブラリへの上げ（配置はしない。2026-11-22 に決めた。[store-screenshots.md](store-screenshots.md)）だけ。この仕組みの前に始めた版（記録の `appStoreVersions` が `null`）には枠を作らない

### App Store Connect の API

2026-11-18 に Apple の文書で確かめた。App Manager の役割の鍵で書き込めるかは文書に書かれていない（役割の表が画像）が、2026-11-20 に OshiCon 1.2.0 を AskHub から審査に出し、版の作成・ビルドの選択・What's New・提出（reviewSubmissions）まで書けることを確かめた。手動の配信・取り下げ・版を消す・release ブランチの main への取り込みは、まだ実地で通していない。

| すること | API |
| --- | --- |
| 版の状態を読む | `GET /v1/apps/{id}/appStoreVersions?filter[appVersionState]=…`（置き換わった版のほかすべて。配信の検知と同じ要求で読む） |
| ビルドを読む | `GET /v1/builds?filter[app]=…&filter[preReleaseVersion.version]=<版>&filter[processingState]=VALID` |
| App Review の情報を読む・書く | `GET /v1/appStoreVersions/{id}/appStoreReviewDetail`（`fields[appStoreReviewDetails]=notes,demoAccountRequired,demoAccountName`。パスワードと連絡先は読まない）、`PATCH /v1/appStoreReviewDetails/{id}`、無ければ `POST /v1/appStoreReviewDetails` |
| 掲載文の言語を読む・What's New と掲載文を書く | `GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations`、`PATCH /v1/appStoreVersionLocalizations/{id}`（`whatsNew`・`description`・`keywords`・`promotionalText`。送った欄だけ変わる） |
| 版を作る・直す・消す | `POST /v1/appStoreVersions`（`platform`・`versionString`・`releaseType`。`earliestReleaseDate` は日時を指定するときだけ）、`PATCH /v1/appStoreVersions/{id}`（送った欄だけ直す。`relationships.build` でビルドも選ぶ）、`DELETE /v1/appStoreVersions/{id}`（まだ審査に出していない版） |
| 提出する | `GET /v1/reviewSubmissions?filter[app]=…&filter[platform]=…&filter[state]=READY_FOR_REVIEW`（開いているものを使う）か `POST /v1/reviewSubmissions` → `POST /v1/reviewSubmissionItems` → `PATCH /v1/reviewSubmissions/{id}`（`submitted: true`） |
| 取り下げる | `PATCH /v1/reviewSubmissions/{id}`（`canceled: true`） |
| 手動で配信する | `POST /v1/appStoreVersionReleaseRequests`（Pending Developer Release の版だけ。取り消せない） |

## 配信の検知と後作業

App Store で対象のアプリの版が配信された（Ready for Sale）ことを司令塔が見つけ、後作業を進める（段階 5 の 2）。
今は develop から上げたビルドを審査に出しているので、release ブランチと main は使わない。release ブランチを使うリリース（「リリースを始める」）を作るときに、取り込みの PR を足す。

### 読むもの

- 鍵は、App Store Connect のチームの API キー（役割は App Manager。Admin は使わない）。Mac mini の Keychain に置く。入れ方は APNs と同じく、.p8 をコマンドで読ませる（`askhub-commander app-store-connect --key-id <鍵の id> --issuer-id <Issuer ID> --key-file <.p8 のパス>`）。.p8 は Mac に残さない。設定には鍵の id と Issuer ID だけを書く。Apple のチームが複数あれば、チームごとに 1 つ足す
- 使うのは読み取りだけ。審査に出す・配信する・取り下げは、人が AskHub で押したときだけ（「リリースを始める」の段階で作る）
- 司令塔は、生きている印を書くとき（10 分ごと）に、前に読んでから 30 分たったリポジトリを、周の外で 1 つずつ読む（対象のアプリのアイコンと同じ形。[architecture.md](architecture.md)）
  1. アプリを探す: リポジトリの base の `*.xcconfig`・`project.yml`・`*.pbxproj` にある `APP_BUNDLE_IDENTIFIER`・`PRODUCT_BUNDLE_IDENTIFIER` の値（`$(…)` を含まないもの）を候補にし、鍵ごとに `GET /v1/apps?filter[bundleId]=…` で探す。返った `bundleId` と完全に一致するものだけを使う（文書に完全一致とは書かれていない）。見つけた鍵とアプリは覚えておく（起動し直したら探し直す）
  2. 配信中の版を読む: `GET /v1/apps/{id}/appStoreVersions?filter[appVersionState]=READY_FOR_DISTRIBUTION&include=build`。`appStoreState`（`READY_FOR_SALE`）は非推奨なので使わない。読むのは `platform`・`versionString` と、ビルドの `version`（番号）・`uploadedDate`
  3. 配信の記録（`releases/<版>.json`。[protocol.md](protocol.md)）が無ければ作り、あれば見つけたプラットフォームを足す
- 読むのは今配信中の版だけで、置き換わった古い版（`REPLACED_WITH_NEW_VERSION`）にはさかのぼらない。AskHub を入れる前に配信した版も、配信中なら同じ後作業をする（タグと Release が手で作ってあれば、それを記録するだけ）
- JWT は ES256（`kid` は鍵の id、`iss` は Issuer ID、`aud` は `appstoreconnect-v1`）。20 分までしか使えないので、15 分使い回して作り直す
- App Store Connect の上限は、鍵ごとに直前の 1 時間で 3,500 回ほど（応答の `X-Rate-Limit`）。1 リポジトリ 30 分に 1〜2 回なので足りる。429 のときは、次に読むときにやり直す

### 後作業の段取り

順に進め、進めるたびに配信の記録に書く。進められなければ、記録の `problem` に理由を書き、次に確かめるとき（10 分ごと）にやり直す。やり直しても進まないもの（人が直すもの）は `needsHuman` にして、クライアントに出す。
タグ・Release・PR は、作る前にあるかを確かめ、二重に作らない。どれも司令塔の持ち主ごとのトークン（Contents・Pull requests・Actions の権限）で行い、ルールセット（PR 必須・例外なし）を越える直接の push はしない。

1. **コミットを求める**: 最初に見つけたプラットフォームのビルドから、そのビルドを上げた Upload の実行を探す
   - `GET /repos/{owner}/{repo}/actions/runs?created=<上げた時刻の 6 時間前>..<上げた時刻>` のうち、ワークフローのファイルが `.github/workflows/upload.yml` で、始めてから終わるまで（終わりは 15 分のゆとりを持つ）の間に上げた時刻が入る実行を候補にする
   - 候補の head が 1 つにそろえば、それを配信したコミットにする（develop と `release/**` が同じコミットで同時に流れたときなど、どの実行が上げたかに関わらずコミットは同じ）。そろわなければ、実行番号がビルドの番号と同じ候補（ビルドの番号を実行番号にするリポジトリ）に絞る
   - それでも決まらなければ、候補ごとに job の一覧（`GET /repos/{owner}/{repo}/actions/runs/{id}/jobs?filter=all`。Re-run の前の試行も含む）と、job のログの先頭 4 MiB（`GET /repos/{owner}/{repo}/actions/jobs/{id}/logs`）を読む。
     `CURRENT_PROJECT_VERSION=<ビルドの番号>`（xcodebuild の引数。`${{ }}` で渡した値はログで展開される）か `CURRENT_PROJECT_VERSION = <ビルドの番号>`（xcodebuild が始めに出すコマンドラインのビルドの設定）がある候補に絞り（見出しのスクリプトは色のエスケープシーケンスつきなので、除いてから探す）、その head が 1 つにそろえば、それを配信したコミットにする
     - prime-pick の 1.4.0（2026-11-24）は、develop と release/1.4.0 の Upload（実行 39・40）が同じコミットで同時に流れ、上げる前に develop の次のコミットの Upload（実行 41）も流れた。ビルドの番号は UTC の日時（`yyyyMMdd.HHmmss`）で、時刻と実行番号では絞れなかった
     - REST の上限を考え、ログは上の 2 つで決まらないときだけ読み、候補が 5 を超えれば読まない。1 つの候補で読むのは、job の一覧と、番号が見つかるまでの job のログ（飛ばした job は読まない）。消えたログ（保存の期限を過ぎた 410）は、番号が出ていないものとして扱う。人が直す問題は 30 分ごとに試し直すので、決まらない間はそのたびに読み直す
     - Xcode に採番させるリポジトリは、上げた番号がログに出ないので、ログでは絞れない
   - それでも決まらない・候補が無いときは、人が直す問題にする（タグ `v<版>` を手で付けると、そのコミットで続ける）
   - ビルドの番号だけでは決めない。Xcode に採番させるリポジトリ（テンプレート・ask-hub-apple）や、実行番号にする前のビルドがあるため（おしかつカウントダウンの 1.0.0 は、ビルド (12) が Upload の実行 13 だった）
   - タグ `v<版>` がすでにあれば、そのタグが指すコミットを使う（人が手で付けたもの）
2. **タグ**: 配信したコミットに、注釈付きのタグ `v<版>` を Git Data API で作る。書き手はワーカーのコミットと同じ（トークンのアカウントの noreply アドレス。[architecture.md](architecture.md)）。本文は 1 行目が `<アプリの名前> <版> (<ビルド>)`、3 行目が `App Store で配信した <版> のビルド (<ビルド>) のコミット。`。ルールセット（`askhub-protect`）はブランチだけが対象なので、タグは止められない
3. **リリース文の下書き**: 常時オンの Mac の Claude（読むだけ）が、配信したコミットの写しを読み、前のタグ（配信したコミットに含まれる `v<版>` のタグのうち、この版より小さい最大のもの）からの変更で、日本語のリリース文を下書きする
   - 材料: その間にマージした epic（状態リポジトリの題と要約）と、PR（マージコミットの題）。前のタグが無い（初めての配信）なら、そのコミットの時点の App Store の説明文（あれば）とアプリの中身。develop の最新から作らない（配信していない変更が入るため）
   - 人が読む文にする。URL・トークンらしい文字列・内部の語（AskHub・epic・ループ・CI など）は入れない。入っていたら、司令塔が書き直させる
4. **人が確かめる**: クライアントの「あなたの番」に下書きを出し、通知する。人はそのまま、または直して「公開する」を押す（`publishGitHubRelease`）。押した本文を記録の `notes.confirmed` に写す
5. **GitHub Release**: 押した本文で、タグ `v<版>` の Release を公開する（名前はタグと同じ。Latest にする）。すでにあれば記録するだけ
6. **次の版**: 1 と並んで、配信を見つけたらすぐ、develop の `MARKETING_VERSION` を次のマイナーに上げる PR を出す
   - ブランチは `askhub/version-<次の版>`、コミットは `[chore] MARKETING_VERSION を <次の版> に上げる`、PR は `【CHORE】MARKETING_VERSION を <次の版> に上げる`
   - 書き換えるのは、develop の `*.xcconfig`・`project.yml`・`*.pbxproj` で、`MARKETING_VERSION` に配信した版か、それより小さい版を書いた行だけ
   - develop の版がもう配信した版より大きければ、上げない（`skipped`）
   - `repo.json` の `build.finalChecks` のチェックがすべて通ったら、マージコミットでマージする。落ちたら人が直す問題にする（司令塔は直さない）
   - 大きく上げたいとき（2.0.0 など）は、次のリリースを始めるときに選び直す

## ワークフロー

| ワークフロー | 動かすとき |
| --- | --- |
| Build | push のたび（ドキュメントだけの変更でも動かす。ワーカーが子 PR と最終 PR でチェックを待つため） |
| Upload | develop と `release/**` への push |
| 最新情報 | リリースのたび。前回のリリースから入った最終 PR をもとに Claude が下書きし、人が確定する |
| 説明文・キーワード・プロモーションテキスト | リリースのとき、Claude が直す案を書き、人が確かめて変えた欄だけを審査に出すときに反映する（上の「リリースを始めてから配信まで」の「掲載文」） |
| スクショ | リリースのとき、画面に差があるときだけ反映する（下の「App Store の素材」） |
| App Store Connect の状態の読み取り | ワークフローではなく司令塔が読む（30 分ごと。下の「配信の検知と後作業」） |

- main では Upload も Archive も走らせない。main に入るのは release ブランチの先頭そのもの
- 後作業の取り込み（release → main、release → develop）は、GitHub Actions の `GITHUB_TOKEN` では行わない。`GITHUB_TOKEN` はブランチ保護の例外に入れられず、既定では PR も作れないため（段階 0 で確認）。配信を見つけたら司令塔が PR を作り、CI が通ったら自動でマージする
- 審査に出したビルドの dSYM は、Upload のときに App Store Connect に送り、クラッシュの解析はそちらに任せる
- archive は、誰でも取れる場所に置かない。GitHub Release にも Actions の成果物（artifact）にも付けない（public のリポジトリでは誰でも取れるため）。GitHub のランナーで作った archive はジョブの終わりに消えるので、残したいときは手元の Mac に置く
- Upload に使う App Store Connect の API の鍵は、今までどおり GitHub の Secrets に置く（今は organization の Secrets。Environment の Secrets に移すのは #1067。[security.md](security.md) の「public のリポジトリと Secrets」）。状態の読み取りに使う鍵は別に作る
- App Store Connect の状態の読み取りと、人が押した操作（審査に出す・配信する・取り下げ）は、ワークフローではなく司令塔が行う（下の「App Store Connect の状態と操作」）

### App Store Connect の状態と操作

2026-11-12 にユーザーが決めた。読み方と鍵の入れ方は、上の「配信の検知と後作業」の「読むもの」。

- App Store Connect の状態（バージョン・ビルドの処理・審査の状態・配信）は、司令塔が読む。読む鍵は、常時オンの Mac の Keychain に置く（Apple のチームが複数あれば、チームごとに 1 つ）
- 読み取りは自動で行う。審査に出す・配信する（手動の配信のとき）・取り下げとやり直しは、人がクライアントで押した（署名した意図の）ときだけ司令塔が行う（段階 5 の 3。[plan.md](plan.md) の「段階 5 の順」）。そのため、鍵の役割は App Manager にする（Admin は使わない）
- GitHub Actions の定期実行で読む形は採らない。状態リポジトリに書くためのトークンを Secrets に置くことになり、public のリポジトリの定期実行は 60 日動きが無いと止まるため。司令塔が止まると読み取りも止まるが、司令塔の見張りで分かる（[operations.md](operations.md) の「司令塔の見張り」）

## 新しいアプリを載せる

App Store Connect にまだアプリが無い・配信中の版が無いアプリを、最初のリリースまで進める（2026-11-20）。アプリの作成は API が無いので人が Web で行い、
司令塔は API で終わったかを確かめて、残りを「あなたの番」のチェックリストに出す。記録は `app-store.json`（[protocol.md](protocol.md)）。

2026-11-20 にユーザーが決めたこと:

- 決まった値（価格は無料・配信の地域はすべて・カテゴリ・コンテンツの権利・プライバシーポリシーの URL）は、人がチェックリストで値を確かめて押したら司令塔が API で書く。Bundle ID の登録も人が押したとき。アプリの作成・App のプライバシー・DSA の申告・年齢制限は人が Web で行う
- 自動で出す。App Store Connect にアプリが無ければ「アプリを作る」を、配信中の版が無いアプリでリリースを始めたら初めての版の残りを出す。出さないリポジトリは「App Store に出さない」で外す
- 初めての版の掲載文（説明文・キーワードなど）は Claude が下書きする（版ごとの掲載文の仕組みに乗せる。上の「掲載文」）

2026-11-21 に足したこと:

- 初めての版の版の項目（サポート URL・著作権表示・App Review の連絡先）もチェックリストに出す。初めての版のリリースを始めて版の枠を作ったときだけ確かめる
- サポート URL・マーケティング URL（任意）・著作権表示は、プライバシーポリシーの URL と同じく決まった値にし、人がチェックリストで値を確かめて押したら司令塔が書く
- App Review の連絡先（姓・名・電話・メール）は、AskHub で終わらせる（App Store Connect を開かない）。個人の情報なので状態リポジトリには置かず、人がチェックリストで「ほかのアプリの連絡先を写す」を押したら、司令塔が同じ鍵のほかのアプリ（配信中か審査に出した版）の連絡先を App Store Connect の中で新しい版に写す。値は記録・ログ・通知に出さず、どのアプリから写したかだけを書く。写せるアプリが無ければ、人が App Store Connect で入れて「終わった」を押す
  - 連絡先は organization の GitHub の Secrets（`APP_REVIEW_CONTACT_*`。テンプレートの `app-store-metadata.yml` が App Review の情報に書く）にもあるが、Secrets は API で値を読めないので、司令塔は使えない。ほかのアプリの連絡先は、そのワークフローが書いた同じ値の見込み

### App Store Connect の API でできること

2026-11-20 に Apple の文書（API は DocC の JSON、役割は Help の役割の表）で確かめた。鍵は App Manager の役割のチームの鍵（Admin は使わない）。

| すること | API | App Manager の鍵で | AskHub では |
| --- | --- | --- | --- |
| アプリ（App のレコード）の作成 | 無い（Apps の文書に、新しいアプリは Web で作るよう書かれている） | —（Web では App Manager で作れる） | 人が Web で作る。司令塔は `GET /v1/apps?filter[bundleId]=…` で見つけたら終わりにする |
| Bundle ID の登録 | `POST /v1/bundleIds`（`identifier`・`name`・`platform`）、読むのは `GET /v1/bundleIds?filter[identifier]=…` | 文書に無い（役割の表では、App Manager は Certificates, Identifiers & Profiles のアクセスを与えられたときだけ。個人の鍵は Provisioning を使えない） | 人が押したら司令塔が登録する。断られたら、Upload の Export（`-allowProvisioningUpdates`。GitHub の Secrets の鍵）に任せる |
| capability | `POST /v1/bundleIdCapabilities` | 同上 | 扱わない（Upload の自動の署名が entitlements から付ける） |
| コンテンツの権利 | `PATCH /v1/apps/{id}`（`contentRightsDeclaration`） | 文書に無い（Web では App Manager が直せる） | 人が押したら書く |
| カテゴリ | `PATCH /v1/appInfos/{id}`（`primaryCategory` などの関係） | できる（Edit App Store details） | 人が押したら書く（主なカテゴリと、ゲームのサブカテゴリ） |
| プライバシーポリシーの URL | `PATCH /v1/appInfoLocalizations/{id}`（`privacyPolicyUrl`） | できる | 人が押したら、まだ書かれていない言語に書く |
| 価格 | `POST /v1/appPriceSchedules`（`baseTerritory`・`manualPrices`）、価格の点は `GET /v1/apps/{id}/appPricePoints?filter[territory]=…` | できる（Edit app pricing and availability） | 人が押したら無料にする（基準の地域の、`customerPrice` が 0 の点） |
| 配信の地域 | `POST /v2/appAvailabilities`（`availableInNewTerritories`・地域ごとの `available`） | できる | 人が押したら、すべての地域と新しい地域に配信する |
| 年齢制限 | `PATCH /v1/ageRatingDeclarations/{id}` | できる（Help） | 人が Web で答える。司令塔は答えていない質問があるかを確かめる |
| App のプライバシー（データの収集） | 無い | —（Web では App Manager で答えられる） | 人が Web で答えて「終わった」を押す |
| DSA（EU のデジタルサービス法）の申告 | 見当たらない | — | 人が Web で答えて「終わった」を押す |
| 初めての版の掲載文 | `POST`・`PATCH /v1/appStoreVersionLocalizations`（`description`・`keywords`・`promotionalText`・`supportUrl`・`marketingUrl`）、`appStoreVersions` の `copyright` | できる | 説明文・キーワード・プロモーションテキストは Claude が下書きし、審査に出すときに書く（上の「掲載文」）。サポート URL・マーケティング URL・著作権表示は、人がチェックリストで値を確かめて押したら、版の枠のうちまだ書いていない言語・版に書く |
| スクショ | `appScreenshotSets`・`appScreenshots` は 4.5.1 で非推奨。新しい App Asset Library（`appAssetLibraryImages`・`appAssetLibraryPlacements`） | できる（文書に明記） | 「App Store の素材」の流れ（段階 5 の 6）。App Asset Library を使う（#1184） |
| App Review の情報 | `POST`・`PATCH /v1/appStoreReviewDetails`（連絡先・デモアカウント・メモ） | 推定でできる（役割の表に行が無い） | メモ・デモアカウントは「App Store の素材」の流れ（段階 5 の 6）。連絡先は、人が押したら同じ鍵のほかのアプリの版から写す（値は状態リポジトリに置かない） |
| 輸出コンプライアンス | `PATCH /v1/builds/{id}`（`usesNonExemptEncryption`） | 文書に無い | テンプレートの Info.plist の `ITSAppUsesNonExemptEncryption`（上の「審査に出す」） |
| 契約・税・口座 | 無い | できない（Account Holder・Admin・Finance） | 無料のアプリは要らない。有料にするときは人が Web で |

- 初めての提出に要るもの（Help の required properties）: App 情報（名前・年齢制限・Bundle ID・SKU・コンテンツの権利・主な言語・主なカテゴリ・DSA の申告）、版（サポート URL・著作権表示・App Review の情報・スクショ・説明文・キーワード・ビルド）、価格と配信の地域、プライバシー（プライバシーポリシーの URL・データの収集）。What's New は 2 つ目の版から
- 文書で確かめられなかったこと: `GET /v1/bundleIds` の `filter[identifier]` が完全一致か（返った `identifier` を比べ直す）、App Manager のチームの鍵で Provisioning（`bundleIds`）を使えるか、価格 0 の点の `customerPrice` の値、`POST /v2/appAvailabilities` を予約注文でない最初の配信に使えるか（文書のページ名が pre-order）、Web で作ったアプリに最初の版・言語・App Review の情報が自動で作られるか。どれも、司令塔が送って断られたら理由を記録に書き、人が Web で行う

### チェックリスト

| 項目 | 確かめ方 | するのは |
| --- | --- | --- |
| Bundle ID の登録（`bundleId`） | `GET /v1/bundleIds?filter[identifier]=<アプリ本体の Bundle ID>`。読めなければ `unknown`（Upload の Export で登録される） | 司令塔（人が押したとき）か、Upload |
| アプリの作成（`app`） | `GET /v1/apps?filter[bundleId]=…` で見つかる | 人（Web。名前・主な言語・Bundle ID・SKU（Bundle ID と同じ）・User Access はチェックリストに案を出す） |
| コンテンツの権利（`contentRights`） | `apps` の `contentRightsDeclaration` がある | 司令塔（人が値を確かめて押したとき） |
| カテゴリ（`category`） | `appInfos` の `primaryCategory` がある | 同上 |
| プライバシーポリシーの URL（`privacyPolicy`） | `appInfoLocalizations` のすべての言語に `privacyPolicyUrl` がある | 同上 |
| 価格（`price`） | `GET /v1/apps/{id}/appPriceSchedule` の `manualPrices` がある | 同上 |
| 配信の地域（`availability`） | `GET /v1/apps/{id}/appAvailabilityV2` がある | 同上 |
| 年齢制限（`ageRating`） | `ageRatingDeclaration` の質問（暴力・性的な内容・ギャンブル・広告・メッセージなど）がすべて答えてある | 人（Web） |
| App のプライバシー（`appPrivacy`） | API が無い | 人（Web。終わったら「終わった」を押す） |
| DSA の申告（`digitalServicesAct`） | API が無い | 人（Web。同上） |
| サポート URL（`supportUrl`） | 版の枠の `GET /v1/appStoreVersions/{id}/appStoreVersionLocalizations` のすべての言語に `supportUrl` がある | 司令塔（人が値を確かめて押したとき。マーケティング URL は任意で一緒に書く） |
| 著作権表示（`copyright`） | 版の枠の `GET /v1/appStoreVersions/{id}` に `copyright` がある | 同上 |
| App Review の連絡先（`reviewContact`） | 版の枠の `GET /v1/appStoreVersions/{id}/appStoreReviewDetail` に `contactFirstName`・`contactLastName`・`contactPhone`・`contactEmail` がそろう（値は記録に書かない。入れていない欄の名前だけ） | 司令塔（人が押したとき。同じ鍵のほかのアプリの、配信中か審査に出した版の 4 つの欄がそろった連絡先を写す）。写せなければ人（Web で入れて「終わった」） |

- 司令塔は、ほかの App Store Connect の読み取りと同じく、生きている印を書くとき（10 分ごと）に、前に読んでから 30 分たったリポジトリを 1 つずつ読む。人が押した後は、待たずに読む
- アプリが無いリポジトリでは、`bundleId` と `app` だけを確かめる。アプリを見つけたら、ほかの項目も確かめる。配信中の版を見つけたら `releasedAt` を付けて、それより後は確かめない
- 版の項目（`supportUrl`・`copyright`・`reviewContact`）は、初めての版のリリースを始めて版の枠（`submissions/<版>.json` の `appStoreVersions`）があるときだけ確かめる。枠が iOS と macOS の 2 つなら、どちらにもそろったら終わり。枠を作ったら 30 分を待たずに確かめ、リリースをやめて枠を消したら項目を外す
- 連絡先を写すときは、同じ鍵のアプリ（`GET /v1/apps`）のうち、このアプリでないものの版（配信中・審査に出した版。`GET /v1/apps/{id}/appStoreVersions`）の App Review の情報を順に読み、4 つの欄がそろったものを選ぶ。新しい版のまだ入れていない欄だけに書き（App Review の情報が無ければ作る）、写したアプリを記録の `settingsRequest.reviewContactFrom` に書く。値はメモリーの中だけで使い、記録・ログ・通知・断られた理由に出さない
- 確かめが合わない（API で読めない・答えてあるのに残る）ときは、人がどの項目でも「終わった」を押して先に進められる（`app` を除く）
- 「あなたの番」には、アプリが無ければ「アプリを作る」、配信中の版が無いアプリでリリースを始めたら「App Store の準備を終える」を出す。どちらも同じチェックリストの画面を開く
- 「App Store に出さない」を押したリポジトリは、確かめも出しもしない（試しのリポジトリなど）。リポジトリの画面から戻せる
- 書き込み（`registerBundleId`・`applyAppStoreSettings`）は、人の意図を受け付けたときだけ。意図の処理では記録に写すだけで、見回りが App Store Connect に送る。断られた項目は記録の `failures` に理由を書き、人が直して押し直すか、Web で行う

## App Store の素材

### スクショ

2026-11-22 に、撮る場所を各リポジトリの GitHub Actions に移すと決めた（[store-screenshots.md](store-screenshots.md)。#1192）。下の今の作りは、実装の PR ごとに直す。

- リリースのたびに撮り、前回 App Store に出したものと見比べる。差があれば、クライアントで Before / After を確かめてから反映する
- 基準の言語は毎回撮る。ほかの言語は、基準の言語で差が出たときか、その言語の文言のファイルが変わったときだけ撮る
- 差のあるものだけを見せる。ほかの言語は一覧で並べ、「まとめて OK」を押せる
- ステータスバーの表示とデモモードのデータを固定し、画面が変わっていなければ同じ画像になるようにする。Xcode や Simulator の更新で全体に差が出たときは、環境の違いによる差の可能性を添える

2026-11-20 にユーザーが決め、#1167 で作り、#1184 で App Asset Library に移した作り:

- 撮るのは、リリースの見回り（`ReleaseWatch`）の段取り。release ブランチを作ったら撮り始めた印（`submissions/<版>.json` の `screenshots.state` が `capturing`）を書き、常時オンの Mac の司令塔の中の、ジョブと同じビルドの枠と Simulator の枠で、見回りの外の Task で撮る（ジョブにはしない。Mac mini では司令塔がワーカーを兼ねていて、動くのは同じプロセス・同じ枠のため）
- 撮り方は、リポジトリの UI テストを流して添付の画像を取り出す（`repo.json` の `build.storeScreenshots`。[protocol.md](protocol.md)）。テストのビルドは 1 回（`build-for-testing`）だけにし、表示サイズの機種ごと・言語ごとに `test-without-building -only-testing:` で流し、言語は環境変数（`TEST_RUNNER_<名前>`）で渡す。結果（xcresult）の添付を `xcresulttool export attachments` で取り出し、添付した順に 1 枚目・2 枚目… とする
- 撮る表示サイズは、配信中の版の App Store Connect にあるものすべて（撮り方に機種の無い表示サイズは「撮らなかった」として知らせる）。表示サイズは App Asset Library の配置グループ（`IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` など）で、値の一覧は App Store Connect のリファレンスデータにしか無い（文書にあるのは 6.9 インチだけ）。撮らなかった表示サイズは配置グループのまま記録に出るので、その値で `build.storeScreenshots.displayTypes` に機種を足す
- iPhone Duo も、ほかの表示サイズと同じに撮る。iPhone Duo の機種は iOS 27.1 のランタイムにしか無く、Xcode 27.1 以上が要る。表示サイズごとの Xcode は持たず、撮る Mac の設定の Xcode 1 つで撮る（Mac mini は 27.1）。機種を用意できない Mac では、その組を撮らずに理由（ランタイムが無い・Xcode の SDK より新しいなど）を出す（2026-11-21 にユーザーが決めた）
- 比べる相手は、配信中の版の配置のスクショ（App Store Connect の CDN の元の大きさの画像）。AskHub が上げた画像（参照名が `askhub-<ファイルの MD5>`）で同じファイルなら差なし、ほかで上げた画像や違うファイルは画素を比べ（色の差 24 以下・違う画素 0.05% 未満は同じとみなす）、変わった所を割合で記録する
- 古い appScreenshotSets は読まない。配信中の版の基準の言語に配置のスクショが無ければ、比べられないので撮らずに `failed` にする（古い API で上げたスクショが配置に出ないときに当たる。2026-11-21 にユーザーが決めた）
- ほかの言語は、基準の言語のどれかの組に差があればすべて撮る。差が無ければ、前に配信した版のタグ（`v<版>`）から release ブランチの先頭までに文言が変わった言語だけを撮る（#1181）。文言の差は、String Catalog（`.xcstrings`）は言語ごとの値で見て（元の言語の値が書かれていないキーはキーそのものを値とし、訳の状態 `state` は比べない）、`.strings`・`.stringsdict` は言語フォルダ（`ja.lproj` など）のファイルが変わったかで見る。App Store Connect の言語とは `build.storeScreenshots.languages` の `language` で結び、親の言語の差は地域の言語にも効くとみなす（`en` が変われば `en-GB` も撮る）。`Base.lproj` の文言・読めない String Catalog があるときと、前の版のタグが無いときは、どの言語が変わったか分からないので、すべての言語を撮る。基準の言語を 1 組も撮れなければ、ほかの言語も撮らない
- 差のある画面は、見本（幅 600 の JPEG）を状態リポジトリ（`store-screenshots/<版>/<撮ったコミット>/…`）に、元の画像を常時オンの Mac に置く。見本は JPEG を base64 にした文字のファイルにし、1 回の撮影の見本を Git Data API の 1 つのコミットでまとめて書く（tree の中身は UTF-8 の文字しか持てないため。見本が何枚でも、書き込みの予算は 3 件。#1196）
- 人は審査に出すシートで、基準の言語の差のある画面を Before / After で見比べ（変わった所に枠）、画面ごとに「前のままにする」を選ぶ。ほかの言語は「まとめて OK」か、開いて画面ごとに選ぶ
- 審査に出すときに、差のある組の、前のままにしなかった差のある画面を元の画像に替え、前のままにした位置には配信中の版の画像（人が Before で見たもの）を置く（2026-11-21 にユーザーが決めた）。差のある画面をすべて前のままにした組も、配信中の版の画像にそろえる。前回の組にあって撮ったものより後ろの位置は消す。差の無い組は触らない。前のままにする位置の配信中の版の画像が、撮ったときの Before（画像の URL）と違えば、人が見ていない画像を置かないよう、人が直す問題にして止める（リリースを始め直すと撮り直す）。この照らし合わせと撮った元の画像があるかは、すべての組で先に確かめてから書き始める（後の組で止まって、先の組だけ書き換わることが無いように）
  - 画像はアプリの App Asset Library に上げる（予約 → 送る → `uploaded` → 処理を待つ）。参照名に MD5 を入れ、ライブラリに同じ画像があれば上げ直さない（言語・版をまたいで使い回す）。前の試行の上げ終わらなかった・処理に失敗した同じ画像は消してから上げる
  - 編集できる版の言語の表示サイズの配置を、置きたい画像の並びにする。同じ画像の配置は使い回し、余った配置を消してから足りない配置を作り（組の上限 10 枚でも詰まらない）、並べ直す（配置の順の要求）。置きたい並びは配信中の版と撮ったものだけで決まるので、途中で止まってもやり直せば同じになる
  - 表示サイズを載せる版（プラットフォーム）は、リファレンスデータの配置グループのプラットフォームで決める（iPhone・iPad・Apple Watch・iMessage は iOS の版）
- 撮れなかった（人が直す失敗）ときは `failed` にし、スクショを変えずに審査に出せる。待てば直る失敗は、撮り始めた印のまま次の見回りでやり直す
- appScreenshotSets / appScreenshots（API 4.5.1 で非推奨）は使わない。#1184 で App Asset Library（画像・配置・配置の順の要求・リファレンスデータ）に移した
- 撮り方の設定の `capture` が `actions` のリポジトリは、Mac で撮らずに、リポジトリの撮影のワークフロー（template 系の `app-store-screenshots.yml`）で撮る（2026-11-22 にユーザーが決めた。[store-screenshots.md](store-screenshots.md)。#1194）。release ブランチを作ったら、その先頭を読んで撮り始めた印（`run.dispatchedAt`）を書き、ワークフローを `upload: false` で `workflow_dispatch` する（app-kit の v1.1.0 以上を入れたリポジトリには、同時に使う macOS ランナーの数 `max_parallel` も送る。同じ持ち主でほかの撮影が動いていれば 1、夜間で同じ持ち主の epic のジョブが無ければ 5、ほかは 3。[store-screenshots.md](store-screenshots.md) の「撮影の並行」。#1233。`return_run_details` で実行の id を記録の `screenshots.run` に書く。送る前に、そのブランチの既存の実行の最大の id を `run.after` に書く。送った後に落ちて id を書けなければ、ブランチの `workflow_dispatch` の実行のうち `after` より新しいものから探し、1 つならそれを使い、2 つ以上なら見分けられないので `failed`、5 分たっても無ければ送り直す）。見回りの周で実行を読み（5 分空ける。様子が変わったときだけ書く）、ワークフローが無い・入力が合わない・トークンで起動できない・取り消された・6 時間で終わらない（取り消す）ときは `failed` にする。実行が終わったら（一部の表示サイズの撮影が失敗した `failure` も、撮れた artifact は残る）、見回りの外の Task で artifact（`screenshots-<artifacts の値>`）を落とし、zip の中身を確かめてから取り出す（`<言語>/<名前>.png` だけ・シンボリックリンクと PNG でないものは断る・大きさの上限。#1196）。`languages` の言語のフォルダの PNG を名前の順に 1 枚目・2 枚目… とし、Actions は 1 回ですべての言語を撮るので、すべての言語を配信中の版と比べる（#1181 の「文言の変わった言語だけ」は `uiTest` だけ）。配信中の版が無い（初めての版）・配信中の版にその組が無い（はじめて iPhone Duo を撮るなど）ときは、すべて新しい画面（Before なし）にし、審査に出す画面では「載せない」を選べる。artifact の無い表示サイズは `skipped` にわけを書く
- 比べ終えたら、差のある画面（初めての版はすべての画面）の元の画像を、人が確かめる前に App Store Connect のライブラリに上げておく（配置はしない。撮り方によらない。2026-11-22 にユーザーが決めた。#1197）。比べた結果は先に記録に書き、撮影は `capturing` のまま `library`（上げた数・置ける数）を持たせる。見回りの周（5 分空ける）で、上げていない画像を上げ（予約 → 送る → `uploaded`。処理は待たない）、参照名（`askhub-<MD5>`）で処理の様子を読む。処理中（`UPLOAD_COMPLETE`）の画像は消さずに待ち、予約だけの画像は上げ直す。処理に失敗した（`FAILED`）画像の画面と、3 時間で終わらない画面には `rejected` にわけを書き、前のままにするしかないものとして決着させる。すべて置ける（か受け付けられない）になったら `captured` にし、審査に出す準備をそろえる。クライアントは撮っている間の段階（GitHub Actions の撮影・取り込み・ライブラリの取り込みの数）を出し、受け付けられなかった画面はわけを出して「前のままにする」から動かせない
- 審査に出すときは、ライブラリの画像を置くだけにする。置けない画像（取り込みの後に消えたなど）は上げ直し、処理中なら提出を待たせて次の見回りでやり直す（人の問題にしない）。受け付けられなかった画面は、人が前のままにしなくても前のままにする。リファレンスデータの応答は、文書の形（1 件のオブジェクト）でも並びでも読む
- 審査に出す前なら、リリースの画面の「スクショを撮り直す…」で、表示サイズ・言語を選んで撮り直せる（`retakeScreenshots`。#1200）。司令塔は頼みを記録の `screenshots.retake` に写し、見回りで今の release ブランチの先頭から撮り直す。Actions の撮影の途中なら、その実行を取り消してから起動し直す。Actions で一部の組だけを撮り直すときは、撮り直す組だけを起動（入力 `display_types`・`languages`）・取り込み、ほかの組は前の結果（見本と元の画像）を引き継ぐ。UI テストの撮り方は、すべて撮り直す（撮っている途中は断る）。頼みを受け付けてから撮り直しを始めるまでは、審査に出す準備をそろえない

### プロダクトページのヘッダーと検索結果の素材

2026-11-23 に、画像は各リポジトリの GitHub Actions で書き出し、AskHub で確かめ、司令塔が App Asset Library に反映する形で作り始めた（[creative-assets.md](creative-assets.md)。#1235）。下の構想は、その設計で決めた所から直す。

- iOS 27 から入ったプロダクトページのヘッダー（21:9 の画像か動画）と、検索結果の素材（3:2）も作る。寸法と安全領域は、Apple の仕様の原文で確かめる
- 作り方は 2 つ用意する
  - コードで描く: 雛形と設定ファイル（文字・色・アプリの画面の配置）から描く。安全領域は雛形の中で守る
  - デザインした画像を使う: 季節の企画など、凝ったものは画像を添付して使う
- リリースとは別の流れで、いつでも差し替えられる（承認済みのものは新しいバージョンを出さずに差し替えられる）

### チャットでの手直し

1. Claude が、スクショ・ヘッダー・検索結果の素材の最初の案を作る
2. クライアントに、App Store での見え方に近い形（検索結果に並ぶ最初の 3 枚・製品ページの上部）で出す。確かめるのは iPhone・基準の言語だけ
3. コメントを書くと、Claude が修正案を作る。前の案と並べて見比べられる。参考の画像も添付できる
4. OK を押すと、残りの言語・iPad・各サイズを自動で作り、文字のはみ出しと安全領域を自動で検査する。問題が無ければ App Store Connect に上げ、問題があったものだけを出す

### デザインの方針

- 画像生成の AI は使わない。Claude が、アプリの実際の画面（デモモードのデータ）と文字・色をコードで組む
- 強いグラデーション・光彩・意味の無い 3D・汎用の抽象的な背景など、AI らしく見える表現を「使わないもの」として決めておく
- 1 枚に 1 つの短い見出しにし、余白を十分に取る
- アプリごとに「デザインの決まり」（配色・書体・言葉づかい）のファイルを持つ。最初は Claude が案を作り、人が承認する
- 写真やイラストが要るときは、デザインした画像の添付で補う
