#!/bin/bash
# epic の最終 PR（epic → develop）の CI の失敗を直す。オーケストレーターが ciFixCommand として呼ぶ。
#   usage: askhub-fix-ci <owner/repo> <checkoutPath> <headBranch> <pullRequest> <headSHA>
#
# ループの作業場所（制御用 worktree・スロット）とは別の一時 worktree で、CI が失敗した head のコミットを直す。
#   - head のコミットで失敗した GitHub Actions の run のログ（gh run view --log-failed）を集め、claude -p に読ませて直させる
#   - CLAUDE.md の検証コマンドを通させてからコミットさせ、このスクリプトが確かめてから head に push する
# 最後の行に結果を出す（オーケストレーターが読む）:
#   ASKHUB_RESULT: fixed       … 直して push した
#   ASKHUB_RESULT: stale       … head が <headSHA> から進んでいた（直さずに終える）
#   ASKHUB_RESULT: unresolved <理由> … 人の対応が要る（終了コード 2）
#
# 環境変数:
#   ASKHUB_CLAUDE    claude の実行ファイル（既定: claude）
#   ASKHUB_LOG_DIR   ログの置き場所（既定: ~/Library/Logs/askhub/loops）
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

REPOSITORY="${1:-}"
CHECKOUT="${2:-}"
HEAD_BRANCH="${3:-}"
PULL_REQUEST="${4:-}"
HEAD_SHA="${5:-}"
if [[ -z "$REPOSITORY" || -z "$CHECKOUT" || -z "$HEAD_BRANCH" || ! "$PULL_REQUEST" =~ ^[0-9]+$ || ! "$HEAD_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  exit 64
fi

CLAUDE_BIN="${ASKHUB_CLAUDE:-claude}"
LOG_DIR="${ASKHUB_LOG_DIR:-$HOME/Library/Logs/askhub/loops}"
REPO_NAME="${REPOSITORY#*/}"
# claude に渡すログは、run ごとに末尾のこの行数まで（失敗の原因は末尾にあることが多い。長すぎるログで文脈を埋めない）
LOG_TAIL_LINES=400

log() { echo "[$(date '+%F %T')] [fix-ci ${REPOSITORY}#${PULL_REQUEST}] $*"; }
unresolved() {
  log "$*"
  echo "ASKHUB_RESULT: unresolved $*"
  exit 2
}

[[ -d "$CHECKOUT/.git" || -f "$CHECKOUT/.git" ]] || unresolved "checkout が見つかりません: ${CHECKOUT}"
mkdir -p "$LOG_DIR"
CLAUDE_LOG="$LOG_DIR/${REPO_NAME}-ci-fix-${PULL_REQUEST}-$(date +%Y%m%d-%H%M%S).log"

# ループの制御用 worktree・スロットには触れない。ralph-loop の Stop hook に捕まらないよう、
# state ファイルの無い一時 worktree で作業する
TMP=$(mktemp -d "${TMPDIR:-/tmp}/askhub-ci-fix-XXXXXX")
WORKTREE="$TMP/worktree"
FAILED_LOG="$TMP/failed-jobs.log"
cleanup() {
  git -C "$CHECKOUT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

git -C "$CHECKOUT" fetch -q origin "$HEAD_BRANCH" || unresolved "origin から ${HEAD_BRANCH} を取得できませんでした"
if [[ "$(git -C "$CHECKOUT" rev-parse "origin/$HEAD_BRANCH")" != "$HEAD_SHA" ]]; then
  log "${HEAD_BRANCH} が ${HEAD_SHA:0:7} から進んでいるので、直さずに終えます（新しい head の CI を待つ）"
  echo "ASKHUB_RESULT: stale"
  exit 0
fi

# head のコミットで失敗した run のログを集める
RUN_IDS=$(gh run list --repo "$REPOSITORY" --commit "$HEAD_SHA" --status failure --limit 100 --json databaseId --jq '.[].databaseId') \
  || unresolved "失敗した run の一覧を取得できませんでした"
[[ -n "$RUN_IDS" ]] || unresolved "${HEAD_SHA:0:7} で失敗した GitHub Actions の run が見つかりませんでした"
: > "$FAILED_LOG"
while IFS= read -r run; do
  [[ -n "$run" ]] || continue
  {
    echo "===== run ${run}: $(gh run view "$run" --repo "$REPOSITORY" --json workflowName,displayTitle --jq '"\(.workflowName) / \(.displayTitle)"' 2>/dev/null || echo '?') ====="
    gh run view "$run" --repo "$REPOSITORY" --log-failed 2>&1 | tail -n "$LOG_TAIL_LINES" || echo "（ログを取得できませんでした）"
    echo
  } >> "$FAILED_LOG"
done <<< "$RUN_IDS"
cp "$FAILED_LOG" "${CLAUDE_LOG%.log}-failed-jobs.log"

git -C "$CHECKOUT" worktree add -q --detach "$WORKTREE" "$HEAD_SHA"
log "失敗した run: $(printf '%s' "$RUN_IDS" | tr '\n' ' ')。claude に直させます（ログ: ${CLAUDE_LOG}）"

PROMPT=$(cat <<EOF
あなたは、epic の最終 PR（${REPOSITORY}#${PULL_REQUEST}、${HEAD_BRANCH}）の CI の失敗を直す担当です。
作業ディレクトリは一時 worktree（${WORKTREE}）で、CI が失敗したコミット ${HEAD_SHA} を checkout しています（detached HEAD）。

失敗した GitHub Actions のジョブのログ（各 run の末尾 ${LOG_TAIL_LINES} 行まで）は ${FAILED_LOG} にあります。

手順:
1. まず CLAUDE.md（と LEARNINGS.md があればそれ）を読む
2. ログから失敗の原因を特定し、直す。テストが失敗しているなら、テストではなく実装の誤りを疑う。
   テストの期待が仕様と食い違っているときだけテストを直す
3. CLAUDE.md の「ビルド・検証」のコマンドのうち、失敗したジョブに対応するものを実行して通す（通らなければ直す。直せなければ unresolved）
4. 変更を git add し、git commit する（メッセージは CLAUDE.md の規約に従う）
5. 次はしない: git push、ブランチの切り替え、テストの削除・スキップ、lint のルールや CI の設定を緩めて失敗を隠すこと、失敗と無関係な変更

CI の環境に依存する一時的な失敗（ネットワーク・Simulator の起動失敗など）で、コードに直すところが無いときは、変更せずに unresolved で理由を書く。

最後の行に、次のどちらかだけを出力する（ほかの文は前の行に書く）:
ASKHUB_RESULT: fixed
ASKHUB_RESULT: unresolved <人に伝える理由（1 行）>
EOF
)

set +e
OUTPUT=$(cd "$WORKTREE" && "$CLAUDE_BIN" -p --permission-mode bypassPermissions "$PROMPT" </dev/null 2>&1 | tee -a "$CLAUDE_LOG")
STATUS=$?
set -e
# 利用上限で終わったときは、オーケストレーターが末尾から解除の時刻を読む
printf '%s\n' "$OUTPUT" | tail -n 5
[[ $STATUS -eq 0 ]] || unresolved "claude が失敗しました（終了コード ${STATUS}。${CLAUDE_LOG}）"

RESULT=$(printf '%s\n' "$OUTPUT" | sed -n 's/^ASKHUB_RESULT: *//p' | tail -1)
case "$RESULT" in
  fixed) ;;
  unresolved*) unresolved "${RESULT#unresolved }" ;;
  *) unresolved "claude の出力から結果を読み取れませんでした（${CLAUDE_LOG}）" ;;
esac

# claude の報告を鵜呑みにせず、コミットが足されていて、元の head を含み、未コミットの変更が無いことを確かめる
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" != "$HEAD_SHA" ]] || unresolved "直したコミットがありません"
git -C "$WORKTREE" merge-base --is-ancestor "$HEAD_SHA" HEAD || unresolved "${HEAD_BRANCH} の元のコミットが含まれていません"
[[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] || unresolved "コミットしていない変更が残っています"

# 直している間に head が進んでいたら上書きしない（先行のコミットを消さない）
git -C "$WORKTREE" push -q --force-with-lease="refs/heads/${HEAD_BRANCH}:${HEAD_SHA}" origin "HEAD:refs/heads/${HEAD_BRANCH}" \
  || unresolved "${HEAD_BRANCH} に push できませんでした（直している間に ${HEAD_BRANCH} が更新された可能性があります）"
log "CI の失敗を直し、${HEAD_BRANCH} に push しました（$(git -C "$WORKTREE" rev-parse --short HEAD)）"
echo "ASKHUB_RESULT: fixed"
