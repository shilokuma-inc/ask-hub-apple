#!/bin/bash
# テンプレートから新しいアプリのリポジトリを作る。オーケストレーターの createRepositoryCommand から呼ぶ。
#   usage: create-repo.sh <テンプレート owner/repo> <owner/repo> <アプリ名> <Bundle ID> [checkout のパス] [public|private]
#
# 1. GitHub にテンプレートからリポジトリを作る（既定は public。既にテンプレートから作られていれば続きから）
# 2. checkout のパスに clone する（空なら一時ディレクトリで作業し、最後に消す = GitHub に作るだけ）
# 3. テンプレートの scripts/rename.sh でアプリ名を変え、Bundle ID を書き、develop に直接 push する
# 4. AskHub のラベルを作り、App Store Connect への登録を needs-verify の Issue にする
#
# 人に伝える行は `ASKHUB_RESULT: …`、失敗の理由は `ASKHUB_ERROR: …` で出す（依頼 Issue にはこの行だけが書かれる。
# ローカルのパスを含めない）。前提を満たさず、やり直しても成功しないときは終了コード 3 で終わる。
set -euo pipefail

# Git hook や launchd から継承した経路変数が別のチェックアウトを指すことがある
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

TEMPLATE="${1:-}"
REPOSITORY="${2:-}"
APP_NAME="${3:-}"
BUNDLE_ID="${4:-}"
CHECKOUT="${5:-}"
VISIBILITY="${6:-public}"
BRANCH="develop"

result() { echo "ASKHUB_RESULT: $*"; }
reject() { echo "ASKHUB_ERROR: $*"; exit 3; }
fail() { echo "ASKHUB_ERROR: $*"; exit 1; }

if [[ -z "$TEMPLATE" || -z "$REPOSITORY" || -z "$APP_NAME" || -z "$BUNDLE_ID" ]]; then
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  exit 64
fi
# 依頼の値はアプリとオーケストレーターでも確かめているが、シェルに渡す前にもう一度絞る
NAME_PATTERN='^[A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_.][A-Za-z0-9_.-]*$'
[[ "$TEMPLATE" =~ $NAME_PATTERN ]] || reject "テンプレートの名前が不正です: $TEMPLATE"
[[ "$REPOSITORY" =~ $NAME_PATTERN ]] || reject "リポジトリ名が不正です: $REPOSITORY"
[[ "$APP_NAME" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || reject "アプリ名は英字で始まる英数字にしてください: $APP_NAME"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || reject "Bundle ID が不正です: $BUNDLE_ID"
[[ "$VISIBILITY" == public || "$VISIBILITY" == private ]] || reject "公開範囲は public か private にしてください: $VISIBILITY"
if [[ -n "$CHECKOUT" && "$CHECKOUT" != /* ]]; then
  reject "clone 先は絶対パスにしてください"
fi
for command in gh git; do
  command -v "$command" >/dev/null 2>&1 || fail "$command が見つかりません"
done

# 1. リポジトリを作る。やり直しで呼ばれたときは、同じテンプレートから作ったものなら続きから進める
if created_from=$(gh api "repos/$REPOSITORY" --jq '.template_repository.full_name // ""' 2>/dev/null); then
  if [[ "$(printf '%s' "$created_from" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$TEMPLATE" | tr '[:upper:]' '[:lower:]')" ]]; then
    reject "$REPOSITORY は既にあります（$TEMPLATE から作ったものではありません）。別の名前で依頼してください"
  fi
  echo "既にテンプレートから作られています: $REPOSITORY"
else
  gh repo create "$REPOSITORY" --template "$TEMPLATE" "--$VISIBILITY" >/dev/null \
    || fail "$TEMPLATE から $REPOSITORY を作れませんでした（gh の権限とリポジトリ名を確認してください）"
  echo "テンプレートから $VISIBILITY で作りました: $REPOSITORY"
fi
# テンプレートからの作成は非同期で、直後はブランチがまだ無いことがある
for _ in $(seq 1 30); do
  gh api "repos/$REPOSITORY/branches/$BRANCH" >/dev/null 2>&1 && break
  sleep 2
done
gh api "repos/$REPOSITORY/branches/$BRANCH" >/dev/null 2>&1 \
  || fail "$REPOSITORY に $BRANCH ブランチがありません（テンプレートの既定ブランチを確認してください）"

# 2. clone する
TEMP_DIR=""
cleanup() { [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"; return 0; }
trap cleanup EXIT
if [[ -z "$CHECKOUT" ]]; then
  TEMP_DIR=$(mktemp -d)
  WORK="$TEMP_DIR/repo"
else
  WORK="$CHECKOUT"
fi
if [[ -e "$WORK" ]]; then
  # insteadOf で書き換える前の、設定に書かれた URL で比べる
  origin=$(git -C "$WORK" config --get remote.origin.url 2>/dev/null || true)
  # ssh と https のどちらの URL でも、末尾の owner/repo で比べる
  origin_name=$(printf '%s' "$origin" | sed -E 's#^.*github\.com[:/]##; s#\.git$##' | tr '[:upper:]' '[:lower:]')
  if [[ "$origin_name" != "$(printf '%s' "$REPOSITORY" | tr '[:upper:]' '[:lower:]')" ]]; then
    reject "clone 先に別のディレクトリがあります（$(basename "$WORK")）。移動するか、別の名前で依頼してください"
  fi
  echo "既にある checkout を使います"
else
  mkdir -p "$(dirname "$WORK")"
  gh repo clone "$REPOSITORY" "$WORK" -- --branch "$BRANCH" >/dev/null 2>&1 \
    || fail "$REPOSITORY を clone できませんでした"
fi
cd "$WORK"
git checkout --quiet "$BRANCH"
git pull --quiet --ff-only origin "$BRANCH"

# 3. アプリ名を変え、Bundle ID を書いて push する
[[ -x scripts/rename.sh ]] || reject "テンプレートに scripts/rename.sh がありません"
OLD_NAME=$(sed -n -E 's/^OLD_NAME="([^"]+)"$/\1/p' scripts/rename.sh | head -n 1)
[[ -n "$OLD_NAME" ]] || reject "scripts/rename.sh から元のアプリ名を読めません"
if [[ -n "$(git status --porcelain)" ]]; then
  fail "checkout に未コミットの変更があります"
fi
if git ls-files | grep -q -- "$OLD_NAME"; then
  scripts/rename.sh "$APP_NAME" "$REPOSITORY" >/dev/null || fail "scripts/rename.sh が失敗しました"
else
  echo "名前は変更済みです"
fi
XCCONFIG="Configs/Project.xcconfig"
if [[ -f "$XCCONFIG" ]]; then
  perl -pi -e "s/^APP_BUNDLE_IDENTIFIER = .*/APP_BUNDLE_IDENTIFIER = $BUNDLE_ID/" "$XCCONFIG"
else
  echo "警告: $XCCONFIG が無いため、Bundle ID を書けませんでした" >&2
fi
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit --quiet -m "[chore] テンプレートから $APP_NAME を作成する"
fi
git push --quiet origin "$BRANCH" || fail "$BRANCH に push できませんでした"
result "アプリ名を $APP_NAME、Bundle ID を $BUNDLE_ID にして $BRANCH に push しました"

# 4. AskHub のラベル（scripts/ralph-setup.sh と同じ）と、App Store Connect への登録の Issue
while IFS='|' read -r name color description; do
  gh label create "$name" --repo "$REPOSITORY" --color "$color" --description "$description" >/dev/null 2>&1 || true
done <<'LABELS'
needs-answer|D93F0B|人間の回答を待っている質問がある
ready-for-loop|0E8A16|Discussion の回答が確定し、ループを始めてよい
manual-loop|C5DEF5|この Discussion のループは手で回す（オーケストレーターは起動しない）
idea-request|5319E7|アプリから出した新機能の依頼
decision-log|1D76DB|epic ごとの仮決め一覧（判断ログ）
needs-verify|FBCA04|実機・実データでの確認が必要
epic-final|B60205|epic から develop への最終 PR
LABELS

ASC_TITLE="【CHORE】App Store Connect にアプリを登録する"
asc_issue=$(gh issue list --repo "$REPOSITORY" --state all --label needs-verify --search "in:title App Store Connect" \
  --json url --jq '.[0].url // ""' 2>/dev/null || true)
if [[ -z "$asc_issue" ]]; then
  asc_issue=$(gh issue create --repo "$REPOSITORY" --title "$ASC_TITLE" --label needs-verify --body "$(cat <<BODY
App Store Connect でのアプリの作成は Web でしか行えないため、手で行ってください。

- [ ] [App Store Connect](https://appstoreconnect.apple.com/apps) で新規 App を作成する（Bundle ID: \`$BUNDLE_ID\`）
- [ ] Bundle ID が一覧に無ければ、[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) で登録する
- [ ] 必要なら Xcode Cloud のワークフローを設定する

終わったらこの Issue を閉じてください。（askhub-orchestrator が作成）
BODY
)" 2>/dev/null || true)
fi
if [[ -n "$asc_issue" ]]; then
  result "App Store Connect への登録を Issue にしました: $asc_issue"
else
  echo "警告: App Store Connect への登録の Issue を作れませんでした" >&2
fi
