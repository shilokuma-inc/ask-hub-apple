#!/bin/bash
# リリース後作業（.github/workflows/release-finish.yml）で、release ブランチを main / develop に取り込む。
#
#   Tools/release_finish_merge.sh main|develop
#
# 1. 取り込み先が release の先頭を含んでいれば何もしない（再実行）。main が無ければ release の先頭から作る
# 2. 取り込み先の先頭で `git merge --no-ff` する（マージコミット）。develop では MARKETING_VERSION を次のパッチにするコミットを足す
#    （配信したバージョンのままだと develop の Upload が閉じたバージョンに上げようとして失敗する。Tools/release_finish.py develop-version）
# 3. develop では、作ったコミットを一時ブランチ（release-finish/<v>/develop）に push し、先頭に check run「No AI Attribution」を付けてから、
#    develop に fast-forward で push する（--force は付けない）。一時ブランチは消す。main はブランチ保護が無いので、そのまま push する
#    develop はブランチ保護で必須チェック「No AI Attribution」（GitHub Actions のチェック）が要り、push するコミットにそのチェックが要る。
#    GITHUB_TOKEN で作った check run は GitHub Actions のものになるので、必須チェックを満たせる。
#    中身の検査（release ブランチにしかないコミットの AI 帰属行）は Release/Finish の check ジョブで済ませてある
# 4. コンフリクトしたとき・push を断られたとき（GITHUB_TOKEN は workflows の権限を持てないので、.github/workflows/ が変わる
#    取り込みは断られる）は、release → 取り込み先の PR を作り（あれば使い。作れなければ Issue で知らせ）、終了コード 1 で止める
#
# 環境変数: VERSION・RELEASE_SHA（check ジョブで確かめた release の先頭）・GITHUB_REPOSITORY・GH_TOKEN・
#           SUMMARY（Job Summary に載せる行をためるファイル）・RUNNER_TEMP・GITHUB_OUTPUT。
# 出力（GITHUB_OUTPUT）: state（created / merged / done / conflict / rejected）・sha（取り込み先の新しい先頭）・pr（PR の URL）・issue（PR を作れなかったときの Issue の URL）
set -euo pipefail

target="${1:?main か develop を指定してください}"
case "$target" in
  main | develop) ;;
  *)
    echo "::error::取り込み先は main か develop です（${target}）"
    exit 2
    ;;
esac

branch="release/${VERSION}"
# develop に push する前に check run を付けるための一時ブランチ（main では使わない）
temp_branch="release-finish/${VERSION}/${target}"
check_name="No AI Attribution"
# release_finish.py はこのスクリプトと同じ Tools/ のもの（起動した ref。取り込みは作業ディレクトリのリポジトリで行う）
tools=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

output() {
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}

summary() {
  echo "$1" >> "$SUMMARY"
}

commit_link() {
  echo "[\`${1:0:7}\`](${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/commit/$1)"
}

# $1: git push の標準エラーを書いたファイル。GitHub の断りの文（remote: の行）を 1 行にまとめる
push_error() {
  local reason
  reason=$(sed -n 's/^remote: *//p' "$1" 2> /dev/null | sed '/^$/d' | head -2 | tr '\n' ' ')
  if [ -z "$reason" ]; then
    reason=$(grep -m 1 -E '^(error|fatal|!)|rejected' "$1" 2> /dev/null || true)
  fi
  echo "${reason:-理由はログを見てください}"
}

# $1: コミット、$2: check run の説明
create_check_run() {
  gh api --silent -X POST "repos/${GITHUB_REPOSITORY}/check-runs" \
    -f name="$check_name" -f head_sha="$1" -f status=completed -f conclusion=success \
    -f "output[title]=Release/Finish が検査しました" -f "output[summary]=$2"
}

# $1: pr（PR の本文）か issue（PR を作れなかったときの Issue の本文）、$2: 理由
write_body() {
  local kind="$1" reason="$2"
  echo "## 概要"
  echo
  if [ "$kind" = "pr" ]; then
    echo "リリース後作業（Release/Finish ${VERSION}）が \`${branch}\` を \`${target}\` に自動で取り込めなかったので、この PR を残しました。"
  else
    echo "リリース後作業（Release/Finish ${VERSION}）が \`${branch}\` を \`${target}\` に自動で取り込めず、PR も作れなかったので、この Issue で知らせます。"
  fi
  echo
  echo "- 理由: ${reason}"
  echo "- 取り込む release の先頭: \`${RELEASE_SHA}\`"
  echo
  echo "## すること"
  echo
  if [ "$kind" = "pr" ]; then
    echo "1. コンフリクトがあれば解いてから、この PR を**マージコミット**でマージする（Squash しない）"
  else
    echo "1. \`${branch}\` → \`${target}\` の PR を作り、コンフリクトがあれば解いてから**マージコミット**でマージする（Squash しない）"
  fi
  echo "2. Actions → Release/Finish → Run workflow で、同じバージョン \`${VERSION}\` で起動し直す（済んだ所は飛ばして、残りのタグ・Release・取り込みを行う）"
  if [ "$kind" = "issue" ]; then
    echo "3. 終わったらこの Issue を閉じる"
  fi
  echo
  echo "手順は docs/release.md の「リリース後作業」の「取り込めなかったとき」を参照してください。"
}

# $1: state（conflict / rejected）、$2: 理由（Markdown の 1 行）
# release → 取り込み先の PR を作って（あれば使って）止める。PR を作れなければ Issue で知らせる。
# 人がコンフリクトを解いて PR をマージし、Release/Finish を起動し直す
stop_with_pull_request() {
  local state="$1" reason="$2" pr="" body="$RUNNER_TEMP/pr-${target}.md"
  output state "$state"
  summary "- ${target}: **取り込めませんでした**（${reason}）"
  if [ "$state" = "rejected" ] && grep -q 'workflow' "$RUNNER_TEMP/push-${target}.err" 2> /dev/null; then
    # GITHUB_TOKEN は workflows の権限を持てない。.github/workflows/ が変わる取り込み（2 回目以降の main など）は自動では push できない
    summary "  GITHUB_TOKEN は \`.github/workflows/\` を変えるコミットを push できません。PR を人がマージしてください（docs/release.md の「リリース後作業」）。"
  fi
  if [ "$target" = "main" ] && [ -z "$(git rev-parse --verify --quiet "refs/remotes/origin/main^{commit}" || true)" ]; then
    summary "  main がまだ無いので PR は作れません。ログを見て、人が release の先頭から main を作ってから起動し直してください。"
    echo "::error::${target} に取り込めませんでした（${state}）"
    exit 1
  fi
  # develop 宛ての PR は必須チェック「No AI Attribution」が要る。release の先頭は check ジョブで検査済みなので check run を付ける
  # （GITHUB_TOKEN で作った PR では no-ai-attribution.yml が動かない）
  if [ "$target" = "develop" ]; then
    create_check_run "$RELEASE_SHA" "${branch} にしかないコミットに AI 帰属行が無いことを、Release/Finish の check ジョブで確かめました。" ||
      summary "  （release の先頭に check run「${check_name}」を付けられませんでした。PR の必須チェックが待ちのままなら、人が確かめてマージしてください）"
  fi
  pr=$(gh pr list --repo "$GITHUB_REPOSITORY" --base "$target" --head "$branch" --state open --json url --jq '.[0].url // ""' 2> /dev/null || true)
  if [ -z "$pr" ]; then
    write_body pr "$reason" > "$body"
    pr=$(gh pr create --repo "$GITHUB_REPOSITORY" --base "$target" --head "$branch" \
      --title "【CHORE】${branch} を ${target} に取り込む" --body-file "$body" 2> "$RUNNER_TEMP/pr-${target}.err") || pr=""
  fi
  if [ -n "$pr" ]; then
    output pr "$pr"
    summary "  PR: ${pr}（コンフリクトがあれば解いてマージコミットでマージし、Release/Finish を同じバージョンで起動し直してください）"
  else
    summary "  PR を作れませんでした（$(head -c 300 "$RUNNER_TEMP/pr-${target}.err" 2> /dev/null | tr '\n' ' ')）。"
    summary "  リポジトリの「Allow GitHub Actions to create and approve pull requests」が無効なときは作れません。人が \`${branch}\` → \`${target}\` の PR を作ってください。"
    # PR を作れなくても人が気づけるよう、Issue で知らせる（同じタイトルの開いた Issue があれば作らない）
    local title="【CHORE】${branch} を ${target} に取り込めませんでした" issue=""
    issue=$(gh issue list --repo "$GITHUB_REPOSITORY" --state open --search "\"${title}\" in:title" --json url,title \
      --jq "map(select(.title == \"${title}\")) | .[0].url // \"\"" 2> /dev/null || true)
    if [ -z "$issue" ]; then
      write_body issue "$reason" > "$body"
      issue=$(gh issue create --repo "$GITHUB_REPOSITORY" --title "$title" --body-file "$body" 2> /dev/null || true)
    fi
    if [ -n "$issue" ]; then
      output issue "$issue"
      summary "  Issue: ${issue}"
    fi
  fi
  echo "::error::${branch} を ${target} に取り込めませんでした（${state}。Job Summary を見てください）"
  exit 1
}

current=$(git rev-parse --verify --quiet "refs/remotes/origin/${target}^{commit}" || true)

if [ -n "$current" ] && git merge-base --is-ancestor "$RELEASE_SHA" "$current"; then
  output state "done"
  output sha "$current"
  summary "- ${target}: すでに \`${branch}\` を含んでいます（$(commit_link "$current")。前の run か人が取り込み済み）"
  exit 0
fi

if [ -z "$current" ]; then
  if [ "$target" != "main" ]; then
    echo "::error::${target} がありません"
    exit 1
  fi
  # 初回のリリース: release の先頭から main を作る（コミットはもうリモートにあるので、一時ブランチも check run も要らない）
  if ! git push --quiet origin "${RELEASE_SHA}:refs/heads/main" 2> "$RUNNER_TEMP/push-main.err"; then
    cat "$RUNNER_TEMP/push-main.err" >&2
    stop_with_pull_request rejected "main を作る push を断られました: $(push_error "$RUNNER_TEMP/push-main.err")"
  fi
  output state created
  output sha "$RELEASE_SHA"
  summary "- main: まだ無かったので、\`${branch}\` の先頭 $(commit_link "$RELEASE_SHA") から作りました"
  exit 0
fi

worktree="$RUNNER_TEMP/merge-${target}"
git worktree add --quiet --detach "$worktree" "$current"
if ! git -C "$worktree" merge --quiet --no-ff --no-edit -m "Merge branch '${branch}' into ${target}" "$RELEASE_SHA"; then
  # shellcheck disable=SC2016  # バッククォートは Markdown のコードスパン（展開しない）
  conflicts=$(git -C "$worktree" diff --name-only --diff-filter=U | head -20 | sed 's/^/`/; s/$/`/' | paste -sd ' ' -)
  git -C "$worktree" merge --abort || true
  stop_with_pull_request conflict "コンフリクト: ${conflicts:-（ファイルを特定できませんでした）}"
fi

if [ "$target" = "develop" ]; then
  python3 "$tools/release_finish.py" --root "$worktree" develop-version --version "$VERSION" > "$RUNNER_TEMP/develop-version.json"
  if [ "$(jq -r '.changed' "$RUNNER_TEMP/develop-version.json")" = "true" ]; then
    next=$(jq -r '.version' "$RUNNER_TEMP/develop-version.json")
    git -C "$worktree" add Configs/Project.xcconfig
    git -C "$worktree" commit --quiet -m "[chore] MARKETING_VERSION を ${next} にする"
    summary "- develop の MARKETING_VERSION: $(jq -r '.previous' "$RUNNER_TEMP/develop-version.json") → ${next}（配信した ${VERSION} のままだと develop の Upload が失敗するため）"
  fi
fi

merged=$(git -C "$worktree" rev-parse HEAD)

pushed=0
if [ "$target" = "main" ]; then
  # main にはブランチ保護が無い（必須チェックも無い）ので、一時ブランチも check run も使わずにそのまま push する
  if git push --quiet origin "${merged}:refs/heads/main" 2> "$RUNNER_TEMP/push-${target}.err"; then
    pushed=1
  fi
else
  # 作ったコミットをリモートに置いてから check run を付ける（check run はリモートにあるコミットにしか付けられない）。
  # 中断した run の一時ブランチが残っていても断られないよう、一時ブランチだけは + で上書きする（develop への push には付けない）
  if ! git push --quiet origin "+${merged}:refs/heads/${temp_branch}" 2> "$RUNNER_TEMP/push-${target}.err"; then
    cat "$RUNNER_TEMP/push-${target}.err" >&2
    stop_with_pull_request rejected "push を断られました: $(push_error "$RUNNER_TEMP/push-${target}.err")"
  fi
  if create_check_run "$merged" "${branch} を ${target} に取り込むマージコミットです。${branch} にしかないコミットに AI 帰属行が無いことを、Release/Finish の check ジョブで確かめました。" &&
    git push --quiet origin "${merged}:refs/heads/${target}" 2> "$RUNNER_TEMP/push-${target}.err"; then
    pushed=1
  fi
  git push --quiet origin --delete "$temp_branch" 2> /dev/null || echo "::warning::一時ブランチ ${temp_branch} を消せませんでした"
fi
if [ "$pushed" != "1" ]; then
  cat "$RUNNER_TEMP/push-${target}.err" >&2 2> /dev/null || true
  stop_with_pull_request rejected "${target} への push を断られました（起動した後に ${target} が進んだか、ブランチ保護）: $(push_error "$RUNNER_TEMP/push-${target}.err")"
fi

output state merged
output sha "$merged"
summary "- ${target}: \`${branch}\` をマージコミット $(commit_link "$merged") で取り込みました"
