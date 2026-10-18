#!/bin/bash
# epic の最終 PR（epic → develop）の第三者レビューの「🔴 要修正」を直して push する。オーケストレーターが fixCommand として呼ぶ（Discussion #503）。
#   usage: askhub-fix-review <owner/repo> <checkoutPath> <headBranch> <baseBranch> <pullRequest> <headSHA>
#
# 確認した head（headSHA）の第三者レビュー（信用する author が書いた目印付きのコメントのうち最新のもの）の要修正だけを、
# ループの作業場所とは別の一時 worktree で claude -p に直させ、CLAUDE.md の検証コマンドを通させてからコミットさせる。
# claude の報告を鵜呑みにせず、コミットが増えたこと・headSHA の上に積んだこと・コミットしていない変更が無いことなどを
# このスクリプトが確かめてから、headSHA を lease にして epic ブランチに push する（間に push されていたら上書きしない）。
# 最後の行に結果を出す（オーケストレーターが読む）:
#   ASKHUB_RESULT: fixed <新しい head の SHA> … 要修正を直して push した
#   ASKHUB_RESULT: stale                    … head が headSHA から進んでいたので、直さなかった（push もしない）
#   ASKHUB_RESULT: failed <理由>             … 直せなかった（終了コード 2）
#
# 環境変数:
#   ASKHUB_CLAUDE            claude の実行ファイル（既定: claude）
#   ASKHUB_GH                gh の実行ファイル（既定: gh）
#   ASKHUB_LOG_DIR           ログの置き場所（既定: ~/Library/Logs/askhub/loops）
#   ASKHUB_TRUSTED_AUTHORS   信用する GitHub アカウント（カンマ区切り。既定: mrs1669）。第三者レビューはこの author のものだけを読む
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

log() { echo "[$(date '+%F %T')] [fix-review ${REPOSITORY}#${PULL_REQUEST}] $*"; }
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
CLAUDE_LOG="$LOG_DIR/${REPO_NAME}-fix-review-${PULL_REQUEST}-$(date +%Y%m%d-%H%M%S).log"

# ループの制御用 worktree・スロットには触れない。ralph-loop の Stop hook に捕まらないよう、
# state ファイルの無い一時 worktree で作業する。レビューの本文は worktree の外に置く
TMP=$(mktemp -d "${TMPDIR:-/tmp}/askhub-fix-review-XXXXXX")
WORKTREE="$TMP/worktree"
cleanup() {
  git -C "$CHECKOUT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# origin の head を REMOTE_HEAD に入れる。読めなければ failed で終わる
# （コマンド置換の中で failed を呼ぶとサブシェルしか終わらないので、置換の外で呼ぶ）
REMOTE_HEAD=""
read_remote_head() {
  local remote
  remote=$(git -C "$CHECKOUT" ls-remote origin "refs/heads/${HEAD_BRANCH}") || failed "origin の ${HEAD_BRANCH} を確かめられませんでした"
  REMOTE_HEAD=$(printf '%s' "$remote" | cut -f1)
}

# 公開のコメントに書かれうる文に、トークンらしい文字列が無いか
contains_token() {
  # pipefail のもとで grep -q に渡すと、文が大きいとき printf が SIGPIPE で終わって見逃すので、-q を使わない
  printf '%s' "$1" | grep -E 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' >/dev/null
}

git -C "$CHECKOUT" fetch -q origin "$HEAD_BRANCH" "$BASE_BRANCH" || failed "origin から ${HEAD_BRANCH} / ${BASE_BRANCH} を取得できませんでした"
[[ "$(git -C "$CHECKOUT" rev-parse "origin/$HEAD_BRANCH")" == "$HEAD_SHA" ]] \
  || stale "${HEAD_BRANCH} が ${HEAD_SHA:0:7} から進んでいるので、直しません"

# 確認した head の第三者レビュー（信用する author のもの・最新）。直すのはこのレビューの要修正だけ
TRUSTED_JSON=$(printf '%s' "$TRUSTED" | tr '[:upper:]' '[:lower:]' | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$' \
  | sed 's/"/\\"/g; s/.*/"&"/' | paste -sd, - | sed 's/.*/[&]/')
if ! "$GH_BIN" api --paginate "repos/${REPOSITORY}/issues/${PULL_REQUEST}/comments" \
    --jq ".[] | select((.user.login | ascii_downcase) | IN(${TRUSTED_JSON}[]))
          | select(.body | test(\"^\\\\s*<!-- ${MARKER} sha=\\\"${HEAD_SHA}\\\"\"; \"i\")) | .body | @base64" \
    > "$TMP/review.b64"; then
  failed "PR のコメントを読めませんでした"
fi
[[ -s "$TMP/review.b64" ]] || failed "${HEAD_SHA:0:7} の第三者レビュー（信用する author のもの）がありません"
REVIEW_FILE="$TMP/review.md"
tail -n 1 "$TMP/review.b64" | base64 --decode > "$REVIEW_FILE"
# 目印は本文の先頭（前の空白・空行は許す。jq の絞り込みと同じ）
MUST=$(grep -m 1 -E "<!-- ${MARKER} " "$REVIEW_FILE" | sed -n 's/.*must="\([0-9]*\)".*/\1/p')
[[ "$MUST" =~ ^[0-9]+$ && "$MUST" -gt 0 ]] || failed "${HEAD_SHA:0:7} の第三者レビューに要修正がありません"

git -C "$CHECKOUT" worktree add -q --detach "$WORKTREE" "$HEAD_SHA"
log "第三者レビューの要修正 ${MUST} 件を直させます（${HEAD_SHA:0:7}。ログ: ${CLAUDE_LOG}）"

PROMPT=$(cat <<EOF
あなたは、epic の最終 PR（${REPOSITORY}#${PULL_REQUEST}、${HEAD_BRANCH} → ${BASE_BRANCH}）の第三者レビューで指摘された「🔴 要修正」を直す担当です。
作業ディレクトリは一時 worktree（${WORKTREE}）で、レビューした head（${HEAD_SHA}）を checkout しています。
第三者レビューのコメントは ${REVIEW_FILE} にあります（要修正 ${MUST} 件）。

手順:
1. まず CLAUDE.md（と LEARNINGS.md があればそれ）を読む
2. レビューの表のうち、重要度が「🔴 要修正」で、対応が「修正済み」でない行だけを直す。「🟡 提案」は直さない。指摘と無関係な変更はしない
3. CLAUDE.md の「ビルド・検証」のコマンドを実行し、すべて通す（通らなければ直す。直せなければ下の failed）
4. 直した内容を git commit する。メッセージは CLAUDE.md のコミットの規約に従い、AI の帰属行（Co-Authored-By など）は入れない。1 コミット = 1 つの論理的変更
5. 次はしない: git push、ブランチの作成・切り替え、git rebase / reset / merge / commit --amend（レビューした head の上にコミットを積むだけ）、PR へのコメント
6. 指摘が誤りだと判断したもの・直すと仕様が変わるものは直さず、下の failed で理由を書く（人が判断する）

最後の行に、次のどちらかだけを出力する（ほかの文は前の行に書く）:
ASKHUB_RESULT: fixed
ASKHUB_RESULT: failed <人に伝える理由（1 行）>
EOF
)

set +e
# プロンプトは標準入力で渡す（値を複数とるオプションに飲み込まれないように）
OUTPUT=$(cd "$WORKTREE" && printf '%s\n' "$PROMPT" | "$CLAUDE_BIN" -p --permission-mode bypassPermissions 2>&1 | tee -a "$CLAUDE_LOG")
STATUS=$?
set -e
# 利用上限で終わったときは、オーケストレーターが末尾から解除の時刻を読む
printf '%s\n' "$OUTPUT" | tail -n 5
[[ $STATUS -eq 0 ]] || failed "claude が失敗しました（終了コード ${STATUS}。${CLAUDE_LOG}）"

RESULT=$(printf '%s\n' "$OUTPUT" | sed -n 's/^ASKHUB_RESULT: *//p' | tail -1)
case "$RESULT" in
  fixed) ;;
  failed*)
    REASON=$(printf '%s' "${RESULT#failed}" | sed 's/^ *//')
    [[ -n "$REASON" ]] || REASON="claude が理由を出力しませんでした（${CLAUDE_LOG}）"
    # 理由はオーケストレーターが PR にコメントしうるので、トークンらしい文字列は出さない
    contains_token "$REASON" && REASON="claude が直せませんでした（理由はログを見てください: ${CLAUDE_LOG}）"
    failed "$REASON"
    ;;
  *) failed "claude の出力から結果を読み取れませんでした（${CLAUDE_LOG}）" ;;
esac

# claude の報告を鵜呑みにせず、push してよい状態かを確かめる
[[ -z "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]] || failed "コミットしていない変更が残っています"
NEW_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
[[ "$NEW_HEAD" != "$HEAD_SHA" ]] || failed "修正のコミットがありません"
git -C "$WORKTREE" merge-base --is-ancestor "$HEAD_SHA" "$NEW_HEAD" || failed "レビューした head（${HEAD_SHA:0:7}）の上にコミットが積まれていません"
[[ -z "$(git -C "$WORKTREE" rev-list --merges "${HEAD_SHA}..${NEW_HEAD}")" ]] || failed "マージコミットが含まれています"
# 空のコミットや元に戻すだけのコミットでは「直した」とみなさない
! git -C "$WORKTREE" diff --quiet "$HEAD_SHA" "$NEW_HEAD" || failed "修正のコミットに変更がありません"
# pipefail のもとで grep -q に渡すと、出力が長いとき git log が SIGPIPE で失敗扱いになるので、変数に入れてから調べる
MESSAGES=$(git -C "$WORKTREE" log --format=%B "${HEAD_SHA}..${NEW_HEAD}")
if printf '%s\n' "$MESSAGES" | grep -i -E '^co-authored-by:|generated with \[?claude' >/dev/null; then
  failed "コミットメッセージに AI の帰属行が含まれています"
fi

# origin の head が確認した head から進んでいたら上書きしない。claude が指示に背いて自分で push した
# （origin の head が直したコミットのどれか）ときは、確かめていない push なので stale ではなく failed にする
check_remote_unchanged() {
  read_remote_head
  [[ "$REMOTE_HEAD" == "$HEAD_SHA" ]] && return 0
  if [[ -n "$REMOTE_HEAD" ]] && git -C "$WORKTREE" rev-list "${HEAD_SHA}..${NEW_HEAD}" | grep -x "$REMOTE_HEAD" >/dev/null; then
    failed "claude が ${HEAD_BRANCH} に push しました（${REMOTE_HEAD:0:7}）。push の前の確認をしていないので、内容を確かめてください"
  fi
  stale "$1"
}
check_remote_unchanged "直している間に ${HEAD_BRANCH} が ${HEAD_SHA:0:7} から進んだので、push しません"
if ! git -C "$WORKTREE" push -q --force-with-lease="refs/heads/${HEAD_BRANCH}:${HEAD_SHA}" origin "HEAD:refs/heads/${HEAD_BRANCH}"; then
  check_remote_unchanged "push の直前に ${HEAD_BRANCH} が ${HEAD_SHA:0:7} から進んだので、push しませんでした"
  failed "${HEAD_BRANCH} に push できませんでした"
fi

COMMITS=$(git -C "$WORKTREE" rev-list --count "${HEAD_SHA}..${NEW_HEAD}")
log "要修正を直し、${HEAD_BRANCH} に push しました（${HEAD_SHA:0:7} → ${NEW_HEAD:0:7}・${COMMITS} コミット）"
echo "ASKHUB_RESULT: fixed ${NEW_HEAD}"
