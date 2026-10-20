#!/bin/bash
# リリース後作業（.github/workflows/release-finish.yml）で、release ブランチを main / develop に取り込む。
#
#   Tools/release_finish_merge.sh main|develop
#
# 1. 取り込み先が release の先頭を含んでいれば取り込まない（再実行。人が PR をマージした後など）。ただし develop の MARKETING_VERSION が
#    <v> 以下のままなら、次のパッチにするコミットだけを 3 と同じ手順で push する。main が無ければ release の先頭から作る
# 2. 取り込み先の先頭で `git merge --no-ff` する（マージコミット）。develop では MARKETING_VERSION を次のパッチにするコミットを足す
#    （配信したバージョンのままだと develop の Upload が閉じたバージョンに上げようとして失敗する。Tools/release_finish.py develop-version）
# 3. develop では、作ったコミットを一時ブランチ（release-finish/<v>/develop）に push し、先頭に check run「No AI Attribution」を付けてから、
#    develop に fast-forward で push する（--force は付けない）。一時ブランチは消す。main はブランチ保護が無いので、そのまま push する
#    develop はブランチ保護で必須チェック「No AI Attribution」（GitHub Actions のチェック）が要り、push するコミットにそのチェックが要る。
#    GITHUB_TOKEN で作った check run は GitHub Actions のものになるので、必須チェックを満たせる。
#    中身の検査（release ブランチにしかないコミットの AI 帰属行）は Release/Finish の check ジョブで済ませてある
# 4. コンフリクトしたとき・push を断られたとき（GITHUB_TOKEN は workflows の権限を持てないので、.github/workflows/ が変わる
#    取り込みは断られる）は、release の先頭から一時ブランチ（release-finish/<v>/pr-<取り込み先>）を作って、そこ → 取り込み先の PR を作り
#    （あれば使い。作れなければ Issue で知らせ）、終了コード 1 で止める。人はそのブランチでコンフリクトを解き、release ブランチは進めない
#
# 環境変数: VERSION・RELEASE_SHA（check ジョブで確かめた release の先頭）・GITHUB_REPOSITORY・GH_TOKEN・
#           SUMMARY（Job Summary に載せる行をためるファイル）・RUNNER_TEMP・GITHUB_OUTPUT。
#           PLANNED（任意。check ジョブの main の判定。done なら main には取り込まない。タグを打った後に release が進んだとき）
# 出力（GITHUB_OUTPUT）: state（created / merged / done / conflict / rejected / version-rejected（取り込み済みの develop のバージョンのコミットを push できなかった））・sha（取り込み先の新しい先頭）・pr（PR の URL）・issue（PR を作れなかったときの Issue の URL）
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
# 取り込めなかったときに残す PR の head。release の先頭から作る（人はここでコンフリクトを解き、release ブランチは進めない）
pr_branch="release-finish/${VERSION}/pr-${target}"
pr_head=""
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

# $1: gh api の標準エラーを書いたファイル。1 行にまとめる
check_run_error() {
  local reason
  reason=$(sed '/^$/d' "$1" 2> /dev/null | head -2 | tr '\n' ' ')
  echo "${reason:-理由はログを見てください}"
}

# $1: コミット、$2: check run の説明
create_check_run() {
  gh api --silent -X POST "repos/${GITHUB_REPOSITORY}/check-runs" \
    -f name="$check_name" -f head_sha="$1" -f status=completed -f conclusion=success \
    -f "output[title]=Release/Finish が検査しました" -f "output[summary]=$2"
}

# 取り込めなかったときに残す PR の head（pr_head）を用意する。release の先頭から一時ブランチ pr_branch を作り、
# 人はこのブランチでコンフリクトを解く。release ブランチは進めない（進めるとタグと release の先頭が合わなくなり、
# 人の push で release の Upload も動く）。作れなければ pr_head は空
prepare_pr_branch() {
  local remote
  pr_head=""
  remote=$(git ls-remote origin "refs/heads/${pr_branch}" 2> /dev/null | cut -f1 || true)
  if [ -n "$remote" ] && git fetch --quiet origin "+refs/heads/${pr_branch}:refs/remotes/origin/${pr_branch}" 2> /dev/null &&
    git merge-base --is-ancestor "$RELEASE_SHA" "$remote"; then
    # 前の run で作ったもの（人がコンフリクトを解いたコミットがあれば、それも残す）
    pr_head="$pr_branch"
    return
  fi
  # 無ければ release の先頭から作る。前の run の古い release の先頭のままなら fast-forward で進める
  # （--force は付けない。人のコミットがあって release の先頭を含まないときは断られるので、人に任せる）
  if git push --quiet origin "${RELEASE_SHA}:refs/heads/${pr_branch}" 2> "$RUNNER_TEMP/pr-branch-${target}.err"; then
    pr_head="$pr_branch"
  else
    cat "$RUNNER_TEMP/pr-branch-${target}.err" >&2
    summary "  PR のブランチ \`${pr_branch}\` を release の先頭から作れませんでした（$(push_error "$RUNNER_TEMP/pr-branch-${target}.err")）。"
  fi
}

# $1: pr（PR の本文）か issue（PR を作れなかったときの Issue の本文）、$2: 理由
write_body() {
  local kind="$1" reason="$2"
  echo "## 概要"
  echo
  if [ "$kind" = "pr" ]; then
    echo "リリース後作業（Release/Finish ${VERSION}）が \`${branch}\` を \`${target}\` に自動で取り込めなかったので、この PR を残しました。"
    echo "PR のブランチ \`${pr_branch}\` は \`${branch}\` の先頭から作った一時ブランチです。"
  else
    echo "リリース後作業（Release/Finish ${VERSION}）が \`${branch}\` を \`${target}\` に自動で取り込めず、PR も作れなかったので、この Issue で知らせます。"
  fi
  echo
  echo "- 理由: ${reason}"
  echo "- 取り込む release の先頭: \`${RELEASE_SHA}\`"
  if [ "$target" = "develop" ]; then
    echo "- \`main\` への取り込み・タグ \`v${VERSION}\`・GitHub Release は済んでいます。残っているのは \`develop\` への取り込みだけです"
  else
    echo "- \`main\` に取り込めていないので、タグ \`v${VERSION}\`・GitHub Release・\`develop\` への取り込みはまだです"
  fi
  echo
  echo "## すること"
  echo
  echo "**\`${branch}\` には push しないでください**（release の先頭が進むと、起動し直したときにタグ・CI を通した先頭と合わなくなり、release ブランチの Upload も動きます）。"
  echo
  if [ "$kind" = "pr" ]; then
    echo "1. コンフリクトがあれば、この PR のブランチ \`${pr_branch}\` で解く（\`${target}\` を取り込むなど）"
    echo "2. この PR を**マージコミット**でマージする（Squash しない）"
  elif [ -n "$pr_head" ]; then
    echo "1. \`${pr_head}\`（\`${branch}\` の先頭から作った一時ブランチ）→ \`${target}\` の PR を作り、コンフリクトがあればそのブランチで解く"
    echo "2. PR を**マージコミット**でマージする（Squash しない）"
  else
    echo "1. \`${branch}\` の先頭 \`${RELEASE_SHA}\` から別のブランチを作り、そのブランチ → \`${target}\` の PR を作って、コンフリクトがあればそのブランチで解く"
    echo "2. PR を**マージコミット**でマージする（Squash しない）"
  fi
  echo "3. Actions → Release/Finish → Run workflow で、同じバージョン \`${VERSION}\` で起動し直す（済んだ所は飛ばして、残りのタグ・Release・取り込みと、\`develop\` の \`MARKETING_VERSION\` を次のパッチにするコミットを行う）"
  if [ "$kind" = "issue" ]; then
    echo "4. 終わったらこの Issue を閉じる"
  fi
  echo
  echo "手順は docs/release.md の「リリース後作業」の「取り込めなかったとき」を参照してください。"
}

# $1: state（conflict / rejected）、$2: 理由（Markdown の 1 行）
# release の先頭から作った一時ブランチ → 取り込み先の PR を作って（あれば使って）止める。PR を作れなければ Issue で知らせる。
# 人がそのブランチでコンフリクトを解いて PR をマージし、Release/Finish を起動し直す
stop_with_pull_request() {
  local state="$1" reason="$2" pr="" body="$RUNNER_TEMP/pr-${target}.md"
  output state "$state"
  summary "- ${target}: **取り込めませんでした**（${reason}）"
  if [ "$state" = "rejected" ] && grep -q 'workflow' "$RUNNER_TEMP/push-${target}.err" 2> /dev/null; then
    # GITHUB_TOKEN は workflows の権限を持てない。.github/workflows/ が変わる取り込み（2 回目以降の main など）は自動では push できない
    summary "  GITHUB_TOKEN は \`.github/workflows/\` を変えるコミットを push できません。PR を人がマージしてください（docs/release.md の「リリース後作業」。改善は #647）。"
  fi
  if [ "$target" = "main" ] && [ -z "$(git rev-parse --verify --quiet "refs/remotes/origin/main^{commit}" || true)" ]; then
    summary "  main がまだ無いので PR は作れません。ログを見て、人が release の先頭から main を作ってから起動し直してください。"
    echo "::error::${target} に取り込めませんでした（${state}）"
    exit 1
  fi
  prepare_pr_branch
  # develop 宛ての PR は必須チェック「No AI Attribution」が要る。PR のブランチの先頭（release の先頭）は check ジョブで検査済みなので check run を付ける
  # （GITHUB_TOKEN で作った PR では no-ai-attribution.yml が動かない）
  if [ "$target" = "develop" ]; then
    create_check_run "$RELEASE_SHA" "${branch} にしかないコミットに AI 帰属行が無いことを、Release/Finish の check ジョブで確かめました。" ||
      summary "  （release の先頭に check run「${check_name}」を付けられませんでした。PR の必須チェックが待ちのままなら、人が確かめてマージしてください）"
  fi
  if [ -n "$pr_head" ]; then
    pr=$(gh pr list --repo "$GITHUB_REPOSITORY" --base "$target" --head "$pr_head" --state open --json url --jq '.[0].url // ""' 2> /dev/null || true)
    if [ -z "$pr" ]; then
      write_body pr "$reason" > "$body"
      pr=$(gh pr create --repo "$GITHUB_REPOSITORY" --base "$target" --head "$pr_head" \
        --title "【CHORE】${branch} を ${target} に取り込む" --body-file "$body" 2> "$RUNNER_TEMP/pr-${target}.err") || pr=""
    fi
  fi
  if [ -n "$pr" ]; then
    output pr "$pr"
    summary "  PR: ${pr}（コンフリクトがあれば PR のブランチ \`${pr_head}\` で解いてマージコミットでマージし、Release/Finish を同じバージョンで起動し直してください。\`${branch}\` には push しない）"
  else
    if [ -n "$pr_head" ]; then
      summary "  PR を作れませんでした（$(head -c 300 "$RUNNER_TEMP/pr-${target}.err" 2> /dev/null | tr '\n' ' ')）。"
      summary "  リポジトリの「Allow GitHub Actions to create and approve pull requests」が無効なときは作れません。人が \`${pr_head}\` → \`${target}\` の PR を作ってください（\`${branch}\` には push しない）。"
    fi
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

# $1: push の標準エラーを書いたファイル。起動した後に取り込み先が進んだだけ（non-fast-forward）なら真
is_non_fast_forward() {
  grep -qE '\[rejected\].*\((non-fast-forward|fetch first)\)' "$1" 2> /dev/null
}

# 作ったコミット $1 を取り込み先に push する。$2: check run の説明（develop だけ）
# 戻り値: 0 = push した / 1 = 取り込み先が進んでいた（non-fast-forward）/ 2 = 断られた / 3 = check run を付けられなかった
publish() {
  local commit="$1" err="$RUNNER_TEMP/push-${target}.err" result=0
  : > "$err"
  if [ "$target" = "main" ]; then
    # main にはブランチ保護が無い（必須チェックも無い）ので、一時ブランチも check run も使わずにそのまま push する
    if git push --quiet origin "${commit}:refs/heads/main" 2> "$err"; then
      return 0
    fi
    is_non_fast_forward "$err" && return 1
    return 2
  fi
  # 作ったコミットをリモートに置いてから check run を付ける（check run はリモートにあるコミットにしか付けられない）。
  # 中断した run の一時ブランチが残っていても断られないよう、一時ブランチだけは + で上書きする（develop への push には付けない）
  git push --quiet origin "+${commit}:refs/heads/${temp_branch}" 2> "$err" || return 2
  if ! create_check_run "$commit" "$2" 2> "$RUNNER_TEMP/check-run-${target}.err"; then
    # push を断られたのではない（develop には何も push していない）。API の失敗の理由を出す
    result=3
  elif ! git push --quiet origin "${commit}:refs/heads/${target}" 2> "$err"; then
    if is_non_fast_forward "$err"; then result=1; else result=2; fi
  fi
  git push --quiet origin --delete "$temp_branch" 2> /dev/null || echo "::warning::一時ブランチ ${temp_branch} を消せませんでした"
  return "$result"
}

# $1: publish の戻り値（2 か 3）。理由の 1 行
publish_error() {
  if [ "$1" = "3" ]; then
    cat "$RUNNER_TEMP/check-run-${target}.err" >&2 2> /dev/null || true
    echo "check run「${check_name}」を付けられませんでした（${target} には push していません）: $(check_run_error "$RUNNER_TEMP/check-run-${target}.err")"
  else
    cat "$RUNNER_TEMP/push-${target}.err" >&2 2> /dev/null || true
    echo "${target} への push を断られました: $(push_error "$RUNNER_TEMP/push-${target}.err")"
  fi
}

# $1: develop の作業ツリー。MARKETING_VERSION が <v> 以下なら次のパッチにするコミットを足し、version_message に Summary の行を入れる
# （変えなければ空）。条件文の中で呼ぶと set -e が効かないので、文として呼ぶ
bump_version() {
  local result="$RUNNER_TEMP/develop-version.json" next
  version_message=""
  if ! python3 "$tools/release_finish.py" --root "$1" develop-version --version "$VERSION" > "$result"; then
    summary "- develop の MARKETING_VERSION を確かめられませんでした（$(jq -r '.error // "ログを見てください"' "$result" 2> /dev/null || echo "ログを見てください")）"
    echo "::error::develop の MARKETING_VERSION を確かめられませんでした"
    exit 1
  fi
  if [ "$(jq -r '.changed' "$result")" = "true" ]; then
    next=$(jq -r '.version' "$result")
    git -C "$1" add Configs/Project.xcconfig
    git -C "$1" commit --quiet -m "[chore] MARKETING_VERSION を ${next} にする"
    version_message="- develop の MARKETING_VERSION: $(jq -r '.previous' "$result") → ${next}（配信した ${VERSION} のままだと develop の Upload が失敗するため）"
  fi
}

# 起動した後に取り込み先が進んで push が non-fast-forward で断られたときは、取り込み先を取り直して 1 回だけやり直す
retried=""
for attempt in 1 2; do
  current=$(git rev-parse --verify --quiet "refs/remotes/origin/${target}^{commit}" || true)

  if [ -n "$current" ] && git merge-base --is-ancestor "$RELEASE_SHA" "$current"; then
    done_message="- ${target}: すでに \`${branch}\` を含んでいます（$(commit_link "$current")。前の run か人が取り込み済み）"
    if [ "$target" = "main" ]; then
      output state "done"
      output sha "$current"
      summary "$done_message"
      exit 0
    fi
    # 人が PR をマージした後の起動し直しでは、develop の MARKETING_VERSION が配信した <v> のままになっている。
    # 取り込みと同じ手順（一時ブランチ → check run → fast-forward）で、次のパッチにするコミットだけを push する
    worktree="$RUNNER_TEMP/version-${target}-${attempt}"
    git worktree add --quiet --detach "$worktree" "$current"
    bump_version "$worktree"
    if [ -z "$version_message" ]; then
      output state "done"
      output sha "$current"
      summary "$done_message"
      exit 0
    fi
    bumped=$(git -C "$worktree" rev-parse HEAD)
    rc=0
    publish "$bumped" "release を取り込んだ develop の MARKETING_VERSION を次のパッチにするコミットです（Release/Finish が作りました）。" || rc=$?
    if [ "$rc" = "0" ]; then
      output state "done"
      output sha "$bumped"
      summary "$done_message"
      summary "${version_message}。コミット $(commit_link "$bumped")${retried:+（起動した後に develop が進んでいたので、新しい先頭で作り直しました）}"
      exit 0
    fi
    if [ "$rc" = "1" ] && [ "$attempt" = "1" ]; then
      retried=1
      git fetch --quiet origin "+refs/heads/${target}:refs/remotes/origin/${target}" || true
      continue
    fi
    # 取り込みは済んでいるので PR は作らない。人が develop の MARKETING_VERSION を直す
    output state "version-rejected"
    summary "$done_message"
    summary "- develop の MARKETING_VERSION: **次のパッチにするコミットを push できませんでした**（$(publish_error "$rc")）。人が develop で \`Configs/Project.xcconfig\` を直すか、起動し直してください"
    echo "::error::develop の MARKETING_VERSION を次のパッチにできませんでした（Job Summary を見てください）"
    exit 1
  fi

  if [ "$target" = "main" ] && [ "${PLANNED:-}" = "done" ] && [ -n "$current" ]; then
    # check が「タグ v<v> を打った main に入っている」とみなした（タグを打った後に release ブランチが進んだ）。進んだ分は main に取り込まない
    output state "done"
    output sha "$current"
    summary "- main: タグ \`v${VERSION}\` を打った main に入っています（\`${branch}\` はタグの後に進んでいますが、進んだ分は main には取り込みません）"
    exit 0
  fi

  if [ -z "$current" ]; then
    if [ "$target" != "main" ]; then
      echo "::error::${target} がありません"
      exit 1
    fi
    # 初回のリリース: release の先頭から main を作る（コミットはもうリモートにあるので、一時ブランチも check run も要らない）
    rc=0
    publish "$RELEASE_SHA" "" || rc=$?
    if [ "$rc" = "0" ]; then
      output state created
      output sha "$RELEASE_SHA"
      summary "- main: まだ無かったので、\`${branch}\` の先頭 $(commit_link "$RELEASE_SHA") から作りました"
      exit 0
    fi
    if [ "$rc" = "1" ] && [ "$attempt" = "1" ]; then
      # 起動した後に main ができていた。取り直して取り込む
      retried=1
      git fetch --quiet origin '+refs/heads/main:refs/remotes/origin/main' || true
      continue
    fi
    stop_with_pull_request rejected "main を作る push を断られました: $(push_error "$RUNNER_TEMP/push-main.err")"
  fi

  worktree="$RUNNER_TEMP/merge-${target}-${attempt}"
  git worktree add --quiet --detach "$worktree" "$current"
  if ! git -C "$worktree" merge --quiet --no-ff --no-edit -m "Merge branch '${branch}' into ${target}" "$RELEASE_SHA"; then
    # shellcheck disable=SC2016  # バッククォートは Markdown のコードスパン（展開しない）
    conflicts=$(git -C "$worktree" diff --name-only --diff-filter=U | head -20 | sed 's/^/`/; s/$/`/' | paste -sd ' ' -)
    git -C "$worktree" merge --abort || true
    stop_with_pull_request conflict "コンフリクト: ${conflicts:-（ファイルを特定できませんでした）}"
  fi

  version_message=""
  if [ "$target" = "develop" ]; then
    bump_version "$worktree"
  fi

  merged=$(git -C "$worktree" rev-parse HEAD)
  rc=0
  publish "$merged" "${branch} を ${target} に取り込むマージコミットです。${branch} にしかないコミットに AI 帰属行が無いことを、Release/Finish の check ジョブで確かめました。" || rc=$?
  if [ "$rc" = "0" ]; then
    output state merged
    output sha "$merged"
    summary "- ${target}: \`${branch}\` をマージコミット $(commit_link "$merged") で取り込みました${retried:+（起動した後に ${target} が進んでいたので、新しい先頭で取り込み直しました）}"
    if [ -n "$version_message" ]; then
      summary "$version_message"
    fi
    exit 0
  fi
  if [ "$rc" = "1" ] && [ "$attempt" = "1" ]; then
    retried=1
    git fetch --quiet origin "+refs/heads/${target}:refs/remotes/origin/${target}" || true
    continue
  fi
  if [ "$rc" = "1" ]; then
    stop_with_pull_request rejected "取り込み直しても ${target} への push を断られました（取り込み先が進み続けています）: $(push_error "$RUNNER_TEMP/push-${target}.err")"
  fi
  stop_with_pull_request rejected "$(publish_error "$rc")"
done
