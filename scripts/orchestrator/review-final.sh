#!/bin/bash
# epic の最終 PR（epic → develop）に第三者レビューをする。オーケストレーターが reviewCommand として呼ぶ（Discussion #503）。
#   usage: askhub-review-final <owner/repo> <checkoutPath> <headBranch> <baseBranch> <pullRequest> <headSHA>
#
# 実装の文脈を持たない claude -p に、確認した head（headSHA）の差分（base...head）をレビューさせる。
# claude には読むことだけを許し（ファイルの変更・コミット・push・コメントはさせない）、レビューの本文だけを返させる。
# 差分の文章でプロンプトインジェクションされても困らないよう、使えるツールを読むもの（Read / Grep / Glob）だけに限り、
# --restricted で読める範囲を一時ディレクトリに閉じ込め、ユーザーの設定（許可のルール）と MCP サーバーも読ませない。
# 投稿する本文にトークンらしい文字列があれば投稿しない。
# 目印（<!-- ralph:third-party-review sha="<headSHA>" must="N" may="M" -->）と見出しはこのスクリプトが付け、PR にコメントする。
# 件数は claude の申告ではなく、本文の表の行（🔴 要修正 / 🟡 提案）からこのスクリプトが数える。
# 最後の行に結果を出す（オーケストレーターが読む）:
#   ASKHUB_RESULT: reviewed must=<N> may=<M> … レビューして PR にコメントした
#   ASKHUB_RESULT: stale                    … head が headSHA から進んでいたので、レビューしなかった（コメントもしない）
#   ASKHUB_RESULT: failed <理由>             … レビューできなかった（終了コード 2）
#
# 環境変数:
#   ASKHUB_CLAUDE            claude の実行ファイル（既定: claude）
#   ASKHUB_GH                gh の実行ファイル（既定: gh）
#   ASKHUB_LOG_DIR           ログの置き場所（既定: ~/Library/Logs/askhub/loops）
#   ASKHUB_TRUSTED_AUTHORS   信用する GitHub アカウント（カンマ区切り。既定: mrs1669）。前回の第三者レビューはこの author のものだけを読む
#   ANTHROPIC_MODEL / CLAUDE_CODE_EFFORT_LEVEL  claude のモデルとエフォート。オーケストレーターが設定の model / effort を渡す
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

REPOSITORY="${1:-}"
CHECKOUT="${2:-}"
HEAD_BRANCH="${3:-}"
BASE_BRANCH="${4:-}"
PULL_REQUEST="${5:-}"
HEAD_SHA="${6:-}"
if [[ -z "$REPOSITORY" || -z "$CHECKOUT" || -z "$HEAD_BRANCH" || -z "$BASE_BRANCH" || ! "$PULL_REQUEST" =~ ^[0-9]+$ \
      || ! "$HEAD_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
  sed -n '3p' "$0" | sed 's/^# //' >&2
  exit 64
fi
HEAD_SHA=$(printf '%s' "$HEAD_SHA" | tr '[:upper:]' '[:lower:]')

CLAUDE_BIN="${ASKHUB_CLAUDE:-claude}"
GH_BIN="${ASKHUB_GH:-gh}"
LOG_DIR="${ASKHUB_LOG_DIR:-$HOME/Library/Logs/askhub/loops}"
TRUSTED="${ASKHUB_TRUSTED_AUTHORS:-mrs1669}"
REPO_NAME="${REPOSITORY#*/}"
MARKER="ralph:third-party-review"

log() { echo "[$(date '+%F %T')] [review-final ${REPOSITORY}#${PULL_REQUEST}] $*"; }
failed() {
  log "$*"
  echo "ASKHUB_RESULT: failed $*"
  exit 2
}
stale() {
  log "$*"
  echo "ASKHUB_RESULT: stale"
  exit 0
}

[[ -d "$CHECKOUT/.git" || -f "$CHECKOUT/.git" ]] || failed "checkout が見つかりません: ${CHECKOUT}"
mkdir -p "$LOG_DIR"
CLAUDE_LOG="$LOG_DIR/${REPO_NAME}-review-${PULL_REQUEST}-$(date +%Y%m%d-%H%M%S).log"

# ループの制御用 worktree・スロットには触れない。ralph-loop の Stop hook に捕まらないよう、
# state ファイルの無い一時 worktree で作業する。差分と前回のレビューは worktree の外に置く
TMP=$(mktemp -d "${TMPDIR:-/tmp}/askhub-review-XXXXXX")
WORKTREE="$TMP/worktree"
cleanup() {
  git -C "$CHECKOUT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# origin の head が、確かめた headSHA のままか（進んでいたら、そのレビューは古い head のものになる）。
# origin を読めなかったときは head が進んだのと区別して failed にする
head_is_current() {
  local remote
  remote=$(git -C "$CHECKOUT" ls-remote origin "refs/heads/${HEAD_BRANCH}") || failed "origin の ${HEAD_BRANCH} を確かめられませんでした"
  [[ "$(printf '%s' "$remote" | cut -f1)" == "$HEAD_SHA" ]]
}

git -C "$CHECKOUT" fetch -q origin "$HEAD_BRANCH" "$BASE_BRANCH" || failed "origin から ${HEAD_BRANCH} / ${BASE_BRANCH} を取得できませんでした"
[[ "$(git -C "$CHECKOUT" rev-parse "origin/$HEAD_BRANCH")" == "$HEAD_SHA" ]] \
  || stale "${HEAD_BRANCH} が ${HEAD_SHA:0:7} から進んでいるので、レビューしません"
git -C "$CHECKOUT" worktree add -q --detach "$WORKTREE" "$HEAD_SHA"

DIFF_FILE="$TMP/diff.patch"
git -C "$WORKTREE" diff "origin/${BASE_BRANCH}...${HEAD_SHA}" > "$DIFF_FILE" || failed "差分（${BASE_BRANCH}...${HEAD_SHA:0:7}）を作れませんでした"
[[ -s "$DIFF_FILE" ]] || failed "差分（${BASE_BRANCH}...${HEAD_SHA:0:7}）が空です"

# 前回の第三者レビュー（信用する author のコメントのうち最新のもの。head は問わない）。直ったかを確かめさせるために渡す
PREVIOUS_FILE="$TMP/previous-review.md"
TRUSTED_JSON=$(printf '%s' "$TRUSTED" | tr '[:upper:]' '[:lower:]' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' \
  | sed 's/"/\\"/g; s/.*/"&"/' | paste -sd, - | sed 's/.*/[&]/')
if ! "$GH_BIN" api --paginate "repos/${REPOSITORY}/issues/${PULL_REQUEST}/comments" \
    --jq ".[] | select((.user.login | ascii_downcase) | IN(${TRUSTED_JSON}[]))
          | select(.body | test(\"^\\\\s*<!-- ${MARKER} \")) | .body | @base64" \
    > "$TMP/previous.b64"; then
  failed "PR のコメントを読めませんでした"
fi
PREVIOUS=""
if [[ -s "$TMP/previous.b64" ]]; then
  PREVIOUS=$(tail -n 1 "$TMP/previous.b64" | base64 --decode)
  printf '%s\n' "$PREVIOUS" > "$PREVIOUS_FILE"
fi
if [[ -n "$PREVIOUS" ]]; then
  PREVIOUS_NOTE="前回の第三者レビュー（${PREVIOUS_FILE}）があります。前回の指摘がこの head で直ったかも確かめ、直っていれば「対応」を「修正済み」にしてください。"
else
  PREVIOUS_NOTE="前回の第三者レビューはありません。"
fi

log "第三者レビューを始めます（${HEAD_SHA:0:7}。ログ: ${CLAUDE_LOG}）"

PROMPT=$(cat <<EOF
あなたは、epic の最終 PR（${REPOSITORY}#${PULL_REQUEST}、${HEAD_BRANCH} → ${BASE_BRANCH}）の作者ではない第三者のレビュアーです。
作業ディレクトリは一時 worktree（${WORKTREE}）で、レビューする head（${HEAD_SHA}）を checkout しています。
レビューする差分（${BASE_BRANCH}...${HEAD_SHA}）は ${DIFF_FILE} にあります。${PREVIOUS_NOTE}

手順:
1. まず CLAUDE.md を読み、「コードレビュー観点」に従う（LEARNINGS.md があればそれも読む）
2. 差分を読み、必要なら周りのコードも読んで、バグ・仕様との食い違い・テストの抜け・セキュリティを見る
3. 次はしない: ファイルの変更、git commit / push / checkout、PR へのコメント（コメントはこのスクリプトが行う）。
   使えるのはファイルを読むツール（Read / Grep / Glob）だけで、読めるのは作業ディレクトリと ${TMP} の中だけ

指摘ごとに重要度を 2 つから選ぶ:
- 🔴 要修正: マージ前に必ず直す（バグ・仕様との食い違い・データの破損や消失・セキュリティ・クラッシュ・テストが無くて壊れても気づけないもの）
- 🟡 提案: 直さなくてもマージできる（読みやすさ・小さな改善・好みの問題）。迷ったら 🟡 提案
カテゴリは UI / ロジック / データ / 並行性 / テスト / セキュリティ / 性能 / ドキュメント / その他 から 1 つ。

出力の形（見出しと目印はスクリプトが付けるので書かない）:
ASKHUB_REVIEW_BEGIN
| # | 重要度 | カテゴリ | 場所 | 指摘 | 対応 |
| --- | --- | --- | --- | --- | --- |
| 1 | 🔴 要修正 | ロジック | \`path/to/File.swift:42\` | … | 修正する |
| 2 | 🟡 提案 | UI | \`path/to/View.swift:18\` | … | 見送り可 |

<details><summary>確認した点</summary>

- …
</details>
ASKHUB_REVIEW_END

- 表は 1 指摘 1 行。🔴 要修正を先に並べ、「#」は 1 からの番号にする。重要度の列には「🔴 要修正」か「🟡 提案」だけを書く
- 「対応」は要修正なら「修正する」、提案なら「見送り可」。前回の指摘がこの head で直っていれば、その行を「修正済み」として残す（件数には数えない）
- 指摘が無ければ表は書かず、「確認した点」だけを書く
- セルの中で | を使うときは \\| と書く。HTML コメント（<!-- -->）は書かない

最後の行には、次の 1 行だけを出力する:
ASKHUB_RESULT: reviewed
EOF
)

set +e
# --tools / --add-dir は値を複数とるので、プロンプトは引数ではなく標準入力で渡す（引数だとツール名として飲み込まれる）
OUTPUT=$(cd "$WORKTREE" && printf '%s\n' "$PROMPT" \
  | "$CLAUDE_BIN" -p --restricted --strict-mcp-config --tools "Read,Grep,Glob" --add-dir "$TMP" 2>&1 | tee -a "$CLAUDE_LOG")
STATUS=$?
set -e
# 利用上限で終わったときは、オーケストレーターが末尾から解除の時刻を読む
printf '%s\n' "$OUTPUT" | tail -n 5
[[ $STATUS -eq 0 ]] || failed "claude が失敗しました（終了コード ${STATUS}。${CLAUDE_LOG}）"

RESULT=$(printf '%s\n' "$OUTPUT" | sed -n 's/^ASKHUB_RESULT: *//p' | tail -1)
[[ "$RESULT" == reviewed* ]] || failed "claude の出力から結果を読み取れませんでした（${CLAUDE_LOG}）"

# 最後の ASKHUB_REVIEW_BEGIN から ASKHUB_REVIEW_END までを本文にする
REVIEW=$(printf '%s\n' "$OUTPUT" | awk '
  /^ASKHUB_REVIEW_BEGIN$/ { body = ""; inside = 1; next }
  /^ASKHUB_REVIEW_END$/ { if (inside) { last = body; found = 1 } inside = 0; next }
  inside { body = body $0 "\n" }
  END { if (found) printf "%s", last }
')
[[ -n "$(printf '%s' "$REVIEW" | tr -d '[:space:]')" ]] || failed "claude の出力にレビューの本文がありません（${CLAUDE_LOG}）"
# 目印は本文の先頭（スクリプトが付ける）でしか読まれないが、HTML コメントは GitHub で見えない文を隠せる。
# 目印を扱うコードを引用しただけで失敗にしないよう、文字参照に書き換えて見える文にする
REVIEW=${REVIEW//<!--/&lt;!--}
# トークンらしい文字列を公開のコメントに出さない
if printf '%s' "$REVIEW" | grep -q -E 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'; then
  failed "レビューの本文にトークンらしい文字列が含まれているので、投稿しません（${CLAUDE_LOG}）"
fi

# 件数は表の行から数える（claude の申告は使わない）。前回の指摘で直ったもの（対応が「修正済み」）は数えない。
# 書式がずれた行を黙って数え落とすと要修正 0 件（マージ可）に倒れるので、表の行（見出しと区切りの行を除く）はすべて、
# 重要度のセル（2 列目）が 🔴 / 🟡 のどちらか 1 つだけを含むことを確かめ、そうでなければ失敗にする
COUNTS=$(printf '%s\n' "$REVIEW" | awk -F'|' '
  /^[[:space:]]*\|/ {
    # 見出し（先頭のセルが #）と区切りの行は飛ばす。本文に「重要度」と書いた行を見出しと取り違えない
    if ($2 ~ /^[[:space:]]*#[[:space:]]*$/ || $0 ~ /^[[:space:]|:-]+$/) next
    severity = $3; last = $(NF - 1)
    must = index(severity, "🔴") > 0; may = index(severity, "🟡") > 0
    if (must == may) { bad++; next }
    if (last ~ /修正済み/) next
    if (must) m++; else y++
  }
  END { printf "%d %d %d", m, y, bad }
')
read -r MUST MAY BAD <<< "$COUNTS"
[[ "$BAD" -eq 0 ]] || failed "レビューの表に重要度（🔴 要修正 / 🟡 提案）を読み取れない行が ${BAD} 行あります（${CLAUDE_LOG}）"

# claude が worktree を変えていても push はしないが、ログに残す
if [[ -n "$(git -C "$WORKTREE" status --porcelain)" || "$(git -C "$WORKTREE" rev-parse HEAD)" != "$HEAD_SHA" ]]; then
  log "警告: claude が worktree を変更しました（破棄します）"
fi

if [[ $MUST -gt 0 ]]; then
  CONCLUSION="❌ 修正が必要（要修正 ${MUST} 件・提案 ${MAY} 件）"
elif [[ $MAY -gt 0 ]]; then
  CONCLUSION="✅ マージ可（提案 ${MAY} 件）"
else
  CONCLUSION="✅ マージ可（指摘なし）"
fi

BODY_FILE="$TMP/comment.md"
{
  printf '<!-- %s sha="%s" must="%s" may="%s" -->\n' "$MARKER" "$HEAD_SHA" "$MUST" "$MAY"
  printf '## 🔍 コードレビュー（第三者）: %s\n\n' "$CONCLUSION"
  # shellcheck disable=SC2016 # バッククォートは Markdown のコードスパン
  printf 'レビューした版: `%s`（この PR の最新。CodeRabbit の代わりにオーケストレーターが行った第三者レビュー）\n\n' "${HEAD_SHA:0:7}"
  printf '%s\n' "$REVIEW"
} > "$BODY_FILE"

# レビューの間に head が進んでいたら、古い head のレビューは出さない
head_is_current || stale "レビューの間に ${HEAD_BRANCH} が ${HEAD_SHA:0:7} から進んだので、コメントしません"
"$GH_BIN" pr comment "$PULL_REQUEST" --repo "$REPOSITORY" --body-file "$BODY_FILE" >/dev/null \
  || failed "PR にコメントできませんでした"

log "第三者レビューをコメントしました（${HEAD_SHA:0:7}・要修正 ${MUST} 件・提案 ${MAY} 件）"
echo "ASKHUB_RESULT: reviewed must=${MUST} may=${MAY}"
