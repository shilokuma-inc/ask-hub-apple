#!/bin/bash
# epic の最終 PR（epic → develop）の CI の失敗を直して push する。オーケストレーターが ciFixCommand として呼ぶ。
#   usage: askhub-fix-ci <owner/repo> <checkoutPath> <headBranch> <baseBranch> <pullRequest> <headSHA>
#
# 確認した head（headSHA）で失敗した GitHub Actions の run のログ（gh run view <run> --log-failed）を集め、
# ループの作業場所とは別の一時 worktree で claude -p に読ませて直させ、CLAUDE.md の検証コマンドを通させてからコミットさせる。
# claude の報告を鵜呑みにせず、コミットが増えたこと・headSHA の上に積んだこと・コミットしていない変更が無いことなどを
# このスクリプトが確かめてから、headSHA を lease にして epic ブランチに push する（間に push されていたら上書きしない）。
# 確かめ方と push の仕方は askhub-fix-review（fix-review.sh）と同じ。
# 最後の行に結果を出す（オーケストレーターが読む）:
#   ASKHUB_RESULT: fixed <新しい head の SHA> … CI の失敗を直して push した
#   ASKHUB_RESULT: stale                    … head が headSHA から進んでいたので、直さなかった（push もしない）
#   ASKHUB_RESULT: failed <理由>             … 直せなかった（終了コード 2）
#
# 環境変数:
#   ASKHUB_CLAUDE            claude の実行ファイル（既定: claude）
#   ASKHUB_GH                gh の実行ファイル（既定: gh）
#   ASKHUB_LOG_DIR           ログの置き場所（既定: ~/Library/Logs/askhub/loops）
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
REPO_NAME="${REPOSITORY#*/}"
# claude に渡すログは、run ごとに末尾のこの行数まで（失敗の原因は末尾にあることが多い。長すぎるログで文脈を埋めない）
LOG_TAIL_LINES=400

log() { echo "[$(date '+%F %T')] [fix-ci ${REPOSITORY}#${PULL_REQUEST}] $*"; }
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
CLAUDE_LOG="$LOG_DIR/${REPO_NAME}-ci-fix-${PULL_REQUEST}-$(date +%Y%m%d-%H%M%S).log"

# ループの制御用 worktree・スロットには触れない。ralph-loop の Stop hook に捕まらないよう、
# state ファイルの無い一時 worktree で作業する。失敗したジョブのログは worktree の外に置く
TMP=$(mktemp -d "${TMPDIR:-/tmp}/askhub-fix-ci-XXXXXX")
WORKTREE="$TMP/worktree"
FAILED_LOG="$TMP/failed-jobs.log"
cleanup() {
  git -C "$CHECKOUT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
# 制限時間を過ぎたオーケストレーターの SIGTERM でも、EXIT の trap（後片付け）を走らせてから終わる
trap 'exit 143' TERM

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

# 確認した head で失敗した run のログを集める（コマンド置換の中で failed を呼ばない）
if ! RUN_IDS=$("$GH_BIN" run list --repo "$REPOSITORY" --commit "$HEAD_SHA" --status failure --limit 100 \
    --json databaseId --jq '.[].databaseId'); then
  failed "失敗した run の一覧を取得できませんでした"
fi
[[ -n "$RUN_IDS" ]] || failed "${HEAD_SHA:0:7} で失敗した GitHub Actions の run が見つかりませんでした"
: > "$FAILED_LOG"
while IFS= read -r run; do
  [[ -n "$run" ]] || continue
  TITLE=$("$GH_BIN" run view "$run" --repo "$REPOSITORY" --json workflowName,displayTitle \
    --jq '"\(.workflowName) / \(.displayTitle)"' 2>/dev/null) || TITLE="?"
  RUN_LOG=$("$GH_BIN" run view "$run" --repo "$REPOSITORY" --log-failed 2>&1) || RUN_LOG="（ログを取得できませんでした）"
  {
    echo "===== run ${run}: ${TITLE} ====="
    printf '%s\n' "$RUN_LOG" | tail -n "$LOG_TAIL_LINES"
    echo
  } >> "$FAILED_LOG"
done <<< "$RUN_IDS"
cp "$FAILED_LOG" "${CLAUDE_LOG%.log}-failed-jobs.log"

git -C "$CHECKOUT" worktree add -q --detach "$WORKTREE" "$HEAD_SHA"
log "失敗した run（$(printf '%s' "$RUN_IDS" | tr '\n' ' ')）を直させます（${HEAD_SHA:0:7}。ログ: ${CLAUDE_LOG}）"

PROMPT=$(cat <<EOF
あなたは、epic の最終 PR（${REPOSITORY}#${PULL_REQUEST}、${HEAD_BRANCH} → ${BASE_BRANCH}）の CI の失敗を直す担当です。
作業ディレクトリは一時 worktree（${WORKTREE}）で、CI が失敗した head（${HEAD_SHA}）を checkout しています。
失敗した GitHub Actions のジョブのログ（run ごとに末尾 ${LOG_TAIL_LINES} 行まで）は ${FAILED_LOG} にあります。

手順:
1. まず CLAUDE.md（と LEARNINGS.md があればそれ）を読む
2. ログから失敗の原因を特定し、直す。テストが失敗しているなら、まず実装の誤りを疑う。テストの期待が仕様と食い違っているときだけテストを直す
3. CLAUDE.md の「ビルド・検証」のコマンドのうち、失敗したジョブに対応するものを実行して通す（通らなければ直す。直せなければ下の failed）
4. 直した内容を git commit する。メッセージは CLAUDE.md のコミットの規約に従い、AI の帰属行（Co-Authored-By など）は入れない。1 コミット = 1 つの論理的変更
5. 次はしない: git push、ブランチの作成・切り替え、git rebase / reset / merge / commit --amend（CI が失敗した head の上にコミットを積むだけ）、
   PR へのコメント、テストの削除・スキップ、lint のルールや CI の設定を緩めて失敗を隠すこと、失敗と無関係な変更
6. CI の環境に依存する一時的な失敗（ネットワーク・Simulator の起動失敗など）で、コードに直すところが無いときは、変更せずに下の failed で理由を書く

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
    # 理由はオーケストレーターが PR にコメントするので、トークンらしい文字列は出さない
    contains_token "$REASON" && REASON="claude が直せませんでした（理由はログを見てください: ${CLAUDE_LOG}）"
    failed "$REASON"
    ;;
  *) failed "claude の出力から結果を読み取れませんでした（${CLAUDE_LOG}）" ;;
esac

# claude の報告を鵜呑みにせず、push してよい状態かを確かめる
[[ -z "$(git -C "$WORKTREE" status --porcelain --untracked-files=all)" ]] || failed "コミットしていない変更が残っています"
NEW_HEAD=$(git -C "$WORKTREE" rev-parse HEAD)
[[ "$NEW_HEAD" != "$HEAD_SHA" ]] || failed "修正のコミットがありません"
git -C "$WORKTREE" merge-base --is-ancestor "$HEAD_SHA" "$NEW_HEAD" || failed "CI が失敗した head（${HEAD_SHA:0:7}）の上にコミットが積まれていません"
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
log "CI の失敗を直し、${HEAD_BRANCH} に push しました（${HEAD_SHA:0:7} → ${NEW_HEAD:0:7}・${COMMITS} コミット）"
echo "ASKHUB_RESULT: fixed ${NEW_HEAD}"
