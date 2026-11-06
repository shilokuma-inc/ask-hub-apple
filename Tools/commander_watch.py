#!/usr/bin/env python3
"""司令塔の見張り（状態リポジトリの .github/workflows/commander-watch.yml。docs/renewal/operations.md の「司令塔の見張り」）。

結果は JSON で標準出力に出す。人に向けた説明は標準エラーにも出す。

    python3 Tools/commander_watch.py check --repo <状態リポジトリの owner/name> [--summary <Markdown を足すファイル>] [--dry-run]
    python3 Tools/commander_watch.py render-workflow --ref <ask-hub-apple のコミット> --output <書き出すファイル>

- `check`: 状態リポジトリの既定のブランチの `commander.json`（司令塔の生きている印）を読む。
  - `seenAt` が 30 分（AskHubKit の `JobTiming.macStaleAfter`）より古い・ファイルが無い・読めない・時刻が 5 分より先に進んでいる
    （Mac の時計が進んでいると、司令塔が止まっても古さで気づけない）ときは、見張りの Issue を立てる。
    まだ戻っていない見張りの Issue（目印が `down`）があれば、開いていても人が閉じていても、重ねて立てない
  - 新しい `seenAt` を見たら、まだ戻っていない見張りの Issue にコメントし、開いていれば閉じて、目印を `recovered` にする
  - 見張りの Issue は、github-actions[bot] が作り、本文の最後の行が目印（`<!-- askhub-commander-watch v1 down -->`）のものだけ
    （private でも、目印だけで見分けない。LEARNINGS.md の「ワークフローが作った Issue を目印に使うとき」）
  - `--dry-run` では、Issue を立てたり閉じたりせず、することだけを出す
- `render-workflow`: 状態リポジトリに入れるワークフローを `--output` に書く。`--ref` のコミットの Tools/askhub-state/commander-watch.yml の
  判定の版（`__ASK_HUB_APPLE_SHA__`）を、そのコミットの SHA に置き換える（ワークフローと判定の版をそろえる）。
  そのコミットに Tools/commander_watch.py があり、リモートのブランチに入っている（ワークフローが取り出せる）かを確かめる

`commander.json` の読み方は、AskHubKit の `StateFileCoder` と同じ（protocol/vectors/state/commander.json の `read` で確かめる）。
GitHub は gh（`GH_TOKEN`）で読み書きし、一覧はページングを最後までたどる（`gh api --paginate`）。
終了コード: 0 = 確かめ終えた（止まっていて Issue を立てたときも 0）/ 1 = GitHub を読めない・書けない / 2 = 引数の誤り。
外の依存は無い（標準ライブラリだけ。状態リポジトリのワークフローは、このファイルだけを取り出して動かす）。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Optional

ROOT = Path(__file__).resolve().parent.parent

#: 状態リポジトリの司令塔の生きている印
COMMANDER_PATH = "commander.json"
#: これより古い `seenAt` は、止まったとみなす（AskHubKit の `JobTiming.macStaleAfter` と同じ。テストで確かめる）
STALE_AFTER = timedelta(minutes=30)
#: 司令塔が生きている印を書く間隔（AskHubKit の `CommanderLoop.Settings.heartbeatInterval` の既定。説明の文だけに使う）
HEARTBEAT_INTERVAL = timedelta(minutes=10)
#: `seenAt` がこれより先なら、Mac の時計が進んでいるとみなす
FUTURE_TOLERANCE = timedelta(minutes=5)
#: 司令塔の LaunchAgent のラベル（AskHubKit の `LaunchAgent.label`）
LAUNCH_AGENT_LABEL = "jp.shilokuma.askhub.commander"

#: GITHUB_TOKEN で作った Issue の author（REST の `user.login`）
ACTIONS_BOT = "github-actions[bot]"
#: 見張りの Issue の目印（本文の最後の行）
MARKER = "<!-- askhub-commander-watch v1 {phase} -->"
MARKER_PATTERN = re.compile(r"<!-- askhub-commander-watch v1 (down|recovered) -->")

#: 状態リポジトリに入れるワークフローの雛形（リポジトリの中の場所）と、判定の版を置き換える印
WORKFLOW_TEMPLATE = "Tools/askhub-state/commander-watch.yml"
WORKFLOW_REF_PLACEHOLDER = "__ASK_HUB_APPLE_SHA__"
#: ワークフローが取り出すこのファイルの、リポジトリの中の場所
SCRIPT_PATH = "Tools/commander_watch.py"

#: 読み取りの再試行（一時的な 5xx などで、毎時の run を失敗にしない）。書き込みは二重にしないよう再試行しない
READ_ATTEMPTS = 3
READ_RETRY_SECONDS = 5

TIMESTAMP_SHAPE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
MAC_NAME = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?")
SELF_CHECK_STATES = ("ok", "missing", "invalid", "expired")
SELF_CHECK_ITEMS = (("keychain", "Keychain"), ("githubToken", "GitHub のトークン"), ("claudeToken", "Claude のトークン"))
SHA = re.compile(r"[0-9a-f]{40}")

#: コマンドを実行する関数（テストで差し替える）。引数のリストと標準入力を受け取り、returncode・stdout・stderr を持つものを返す
Runner = Callable[[list, Optional[str]], "subprocess.CompletedProcess[str]"]


class Failure(Exception):
    """GitHub を読めない・書けないなど、確かめ終えられなかった"""


class UsageError(Exception):
    pass


def run_command(argv: list, stdin: str | None = None) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, input=stdin, capture_output=True, text=True, encoding="utf-8", errors="replace")


def first_lines(text: str, count: int = 2) -> str:
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return " ".join(lines[:count]) or "理由はログを見てください"


# MARK: commander.json を読む


def parse_timestamp(value: object) -> datetime | None:
    """プロトコルの時刻（UTC の ISO 8601 で秒まで）。決まった形でない・存在しない日付なら None"""
    if not isinstance(value, str) or not TIMESTAMP_SHAPE.fullmatch(value):
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def is_mac_name(value: object) -> bool:
    return isinstance(value, str) and MAC_NAME.fullmatch(value) is not None


def _reject_constant(name: str) -> None:
    raise ValueError(f"{name} は JSON の値ではない")


def read_commander(text: str) -> dict:
    """`commander.json` を読む。`outcome` は StateFileCoder の結果と同じ（valid・notJSON・missingVersion・unsupportedVersion・malformed）。
    知らない欄は読み飛ばす。valid のときは `file` に中身（`seenAt` は datetime）を入れ、それ以外は `problem` に理由を入れる"""
    try:
        value = json.loads(text, parse_constant=_reject_constant)
    except ValueError:
        return {"outcome": "notJSON", "problem": "JSON として読めません"}

    def malformed(problem: str) -> dict:
        return {"outcome": "malformed", "problem": problem}

    if not isinstance(value, dict):
        return malformed("最上位が object ではありません")
    version = value.get("v")
    if version is None:
        return {"outcome": "missingVersion", "problem": "v がありません"}
    if isinstance(version, bool) or not isinstance(version, int):
        return malformed("v が整数ではありません")
    if version != 1:
        return {"outcome": "unsupportedVersion", "problem": f"知らない版です（v: {version}）"}

    problems = []
    if not is_mac_name(value.get("mac")):
        problems.append("mac が Mac の名前の形ではありません")
    seen_at = parse_timestamp(value.get("seenAt"))
    if seen_at is None:
        problems.append("seenAt が時刻の形ではありません")
    versions = value.get("versions")
    if not isinstance(versions, dict):
        problems.append("versions がありません")
    else:
        if not isinstance(versions.get("commander"), str) or not versions["commander"]:
            problems.append("versions.commander が空です")
        if versions.get("claude") is not None and not isinstance(versions["claude"], str):
            problems.append("versions.claude が文字列ではありません")
    self_check = value.get("selfCheck")
    if not isinstance(self_check, dict):
        problems.append("selfCheck がありません")
    else:
        if parse_timestamp(self_check.get("checkedAt")) is None:
            problems.append("selfCheck.checkedAt が時刻の形ではありません")
        for key, _ in SELF_CHECK_ITEMS:
            if self_check.get(key) not in SELF_CHECK_STATES:
                problems.append(f"selfCheck.{key} が {'・'.join(SELF_CHECK_STATES)} のどれでもありません")
        for key in ("githubTokenExpiresAt", "claudeTokenExpiresAt"):
            if self_check.get(key) is not None and parse_timestamp(self_check[key]) is None:
                problems.append(f"selfCheck.{key} が時刻の形ではありません")
    if problems:
        return malformed("、".join(problems))
    return {"outcome": "valid", "file": {**value, "seenAt": seen_at, "seenAtText": value["seenAt"]}}


# MARK: 判定


def assess(text: str | None, now: datetime) -> dict:
    """`commander.json` の中身（無ければ None）から、司令塔の様子を決める。
    `state` は alive（動いている）・stale（古い）・missing（無い）・unreadable（読めない）・future（時刻が先に進んでいる）"""
    if text is None:
        return {"state": "missing"}
    reading = read_commander(text)
    if reading["outcome"] != "valid":
        return {"state": "unreadable", "outcome": reading["outcome"], "problem": reading["problem"]}
    commander = reading["file"]
    age = now - commander["seenAt"]
    status = {"commander": commander, "age": age}
    if age < -FUTURE_TOLERANCE:
        return {"state": "future", **status}
    # AskHubKit の isOlder と同じく、ちょうどは古いとみなさない
    if age > STALE_AFTER:
        return {"state": "stale", **status}
    return {"state": "alive", **status}


def watch_issues(issues: list) -> list:
    """Issue の一覧から見張りの Issue を選ぶ。`phase` は目印の down（まだ戻っていない）・recovered（戻った）"""
    found = []
    for issue in issues:
        if issue.get("author") != ACTIONS_BOT:
            continue
        lines = [line.strip() for line in (issue.get("body") or "").splitlines() if line.strip()]
        match = MARKER_PATTERN.fullmatch(lines[-1]) if lines else None
        if match:
            found.append({**issue, "phase": match.group(1)})
    return sorted(found, key=lambda issue: issue["number"])


def plan(status: dict, issues: list) -> list:
    """することを決める。`issues` は watch_issues の結果"""
    pending = [issue for issue in issues if issue["phase"] == "down"]
    if status["state"] == "alive":
        return [{"action": "recover", "issue": issue} for issue in pending]
    if pending:
        # 知らせ済み（人が閉じていても、戻るまでは重ねない）
        return [{"action": "notified", "issue": issue} for issue in pending]
    return [{"action": "open"}]


# MARK: 文面


STATE_LABELS = {
    "alive": "動いている", "stale": "印が古い", "missing": "印が無い", "unreadable": "印を読めない", "future": "印の時刻が先に進んでいる",
}


def minutes(delta: timedelta) -> int:
    """分（切り捨て）。先の時刻はマイナス"""
    seconds = int(delta.total_seconds())
    return seconds // 60 if seconds >= 0 else -((-seconds) // 60)


def stale_minutes() -> int:
    return minutes(STALE_AFTER)


def format_time(moment: datetime) -> str:
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def relative_text(age_minutes: int) -> str:
    return f"{-age_minutes} 分先" if age_minutes < 0 else f"{age_minutes} 分前"


def seen_cell(status: dict) -> str:
    return f"{status['commander']['seenAtText']}（{relative_text(minutes(status['age']))}）"


def versions_cell(commander: dict) -> str:
    # 版は司令塔が書いた任意の文字列なので、表を崩さないよう逃がして短くする
    versions = commander["versions"]
    parts = [f"司令塔 {cell(versions['commander'])[:40]}"]
    if versions.get("claude"):
        parts.append(f"Claude Code {cell(versions['claude'])[:40]}")
    return "・".join(parts)


def self_check_cell(commander: dict) -> str:
    check = commander["selfCheck"]
    parts = [f"{label}: {check[key]}" for key, label in SELF_CHECK_ITEMS]
    return f"{'・'.join(parts)}（{check['checkedAt']}）"


def issue_title(status: dict) -> str:
    state = status["state"]
    if state == "stale":
        return f"【見張り】司令塔の生きている印が {stale_minutes()} 分より長く更新されていません"
    if state == "missing":
        return f"【見張り】司令塔の生きている印（{COMMANDER_PATH}）がありません"
    if state == "unreadable":
        return f"【見張り】司令塔の生きている印（{COMMANDER_PATH}）を読めません"
    return "【見張り】司令塔の生きている印の時刻が先に進んでいます"


def issue_summary(status: dict) -> str:
    state = status["state"]
    if state == "stale":
        return (f"司令塔の生きている印（`{COMMANDER_PATH}` の `seenAt`）が、{minutes(status['age'])} 分更新されていません"
                f"（司令塔は {minutes(HEARTBEAT_INTERVAL)} 分ごとに書き、{stale_minutes()} 分を超えたら止まったとみなします）。\n"
                "司令塔が止まっているか、Mac がスリープ・オフラインになっているか、GitHub に書けなくなっています。")
    if state == "missing":
        return (f"状態リポジトリに司令塔の生きている印（`{COMMANDER_PATH}`）がありません。\n"
                "司令塔がまだ一度も書いていない（入れていない・最初の起動で止まった）か、ファイルが消されています。")
    if state == "unreadable":
        return (f"司令塔の生きている印（`{COMMANDER_PATH}`）を読めません（{status['outcome']}: {status['problem']}）。\n"
                "司令塔とこの見張りの版が合っていない（見張りの判定が古い）か、ファイルが壊れています。")
    return (f"司令塔の生きている印（`{COMMANDER_PATH}` の `seenAt`）が、今より {-minutes(status['age'])} 分先の時刻です。\n"
            "Mac の時計が進んでいるとみられます。このままでは、司令塔が止まっても見張りが古さで気づけません。")


def issue_body(status: dict, now: datetime) -> str:
    lines = [issue_summary(status), "", "| 項目 | 値 |", "| --- | --- |"]
    if "commander" in status:
        commander = status["commander"]
        lines += [f"| 最後の `seenAt` | {seen_cell(status)} |",
                  f"| Mac | `{commander['mac']}` |",
                  f"| 版 | {versions_cell(commander)} |",
                  f"| 起動したときの自己診断 | {self_check_cell(commander)} |"]
    lines += [f"| 確かめた時刻 | {format_time(now)} |", "",
              "### 確かめること", "",
              "司令塔の Mac の画面の端末で確かめます（ssh からは Keychain を読めません）。", "",
              "1. Mac が起きていて、ネットワークにつながっているか",
              f"2. 司令塔が動いているか: `launchctl print gui/$(id -u)/{LAUNCH_AGENT_LABEL}`",
              "3. ログ: `~/Library/Logs/AskHub/commander.log`",
              "4. 設定と Keychain の様子（値は出ません）: `askhub-commander check`", "",
              "司令塔が戻って新しい `seenAt` を書くと、見張りがこの Issue にコメントして閉じます。"
              "戻る前にこの Issue を閉じても、戻るまでは新しい Issue を立てません。",
              "手順と見張りの止め方は、shilokuma-inc/ask-hub-apple の `docs/renewal/operations.md` の「司令塔の見張り」にあります。", "",
              MARKER.format(phase="down")]
    return "\n".join(lines) + "\n"


def recovery_comment(status: dict, closing: bool) -> str:
    commander = status["commander"]
    text = (f"司令塔が戻りました（`seenAt`: {commander['seenAtText']}・Mac `{commander['mac']}`・{versions_cell(commander)}）。")
    if closing:
        text += "見張りがこの Issue を閉じます。"
    return text + "\n"


def recovered_body(body: str) -> str:
    """本文の最後の目印を recovered にする"""
    lines = (body or "").rstrip().splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if lines:
        lines[-1] = MARKER.format(phase="recovered")
    return "\n".join(lines) + "\n"


# MARK: GitHub


class GitHub:
    """gh で状態リポジトリを読み書きする"""

    def __init__(self, repo: str, runner: Runner, sleep: Callable[[float], None] = time.sleep):
        self.repo = repo
        self.runner = runner
        self.sleep = sleep

    def _read(self, argv: list, failure: str, allow_missing: bool = False) -> str | None:
        completed = None
        for attempt in range(READ_ATTEMPTS):
            if attempt:
                self.sleep(READ_RETRY_SECONDS * attempt)
            completed = self.runner(argv, None)
            if completed.returncode == 0:
                return completed.stdout
            if "(HTTP 404)" in (completed.stderr or ""):
                if allow_missing:
                    return None
                break
        raise Failure(f"{failure}: {first_lines(completed.stderr)}")

    def _write(self, method: str, path: str, fields: dict, failure: str) -> dict:
        completed = self.runner(["gh", "api", "--method", method, path, "--input", "-"], json.dumps(fields, ensure_ascii=False))
        if completed.returncode != 0:
            raise Failure(f"{failure}: {first_lines(completed.stderr)}")
        try:
            return json.loads(completed.stdout or "{}")
        except ValueError:
            return {}

    def commander(self) -> str | None:
        """既定のブランチの commander.json の中身。無ければ None"""
        return self._read(["gh", "api", "-H", "Accept: application/vnd.github.raw+json", f"repos/{self.repo}/contents/{COMMANDER_PATH}"],
                          f"{COMMANDER_PATH} を読めませんでした", allow_missing=True)

    def issues(self) -> list:
        """閉じたものも含めたすべての Issue（PR は除く）"""
        output = self._read(["gh", "api", "--paginate", f"repos/{self.repo}/issues?state=all&per_page=100", "--jq",
                             ".[] | select(.pull_request == null) | {number, state, html_url, body, author: .user.login}"],
                            "Issue の一覧を読めませんでした")
        issues = []
        for line in (output or "").splitlines():
            if line.strip():
                try:
                    issues.append(json.loads(line))
                except ValueError as error:
                    raise Failure(f"Issue の一覧を読めませんでした: {error}") from error
        return issues

    def create_issue(self, title: str, body: str) -> dict:
        return self._write("POST", f"repos/{self.repo}/issues", {"title": title, "body": body}, "見張りの Issue を立てられませんでした")

    def comment(self, number: int, body: str) -> None:
        self._write("POST", f"repos/{self.repo}/issues/{number}/comments", {"body": body}, f"#{number} にコメントできませんでした")

    def update_issue(self, number: int, fields: dict) -> None:
        self._write("PATCH", f"repos/{self.repo}/issues/{number}", fields, f"#{number} を更新できませんでした")


# MARK: check


def check(repo: str, github: GitHub, now: datetime, dry_run: bool = False) -> dict:
    status = assess(github.commander(), now)
    issues = watch_issues(github.issues())
    steps = plan(status, issues)
    done = []
    for step in steps:
        issue = step.get("issue") or {}
        entry = {"action": step["action"], "number": issue.get("number"), "url": issue.get("html_url")}
        if step["action"] == "open" and not dry_run:
            created = github.create_issue(issue_title(status), issue_body(status, now))
            entry.update(number=created.get("number"), url=created.get("html_url"))
        elif step["action"] == "recover":
            closing = issue["state"] == "open"
            entry["closed"] = closing
            if not dry_run:
                github.comment(issue["number"], recovery_comment(status, closing))
                fields = {"body": recovered_body(issue.get("body") or "")}
                if closing:
                    fields.update(state="closed", state_reason="completed")
                github.update_issue(issue["number"], fields)
        done.append(entry)
    result = {"ok": True, "repo": repo, "dryRun": dry_run, "checkedAt": format_time(now), "state": status["state"],
              "staleAfterMinutes": stale_minutes(), "actions": done, "messages": [describe(status, done, dry_run)]}
    if "commander" in status:
        commander = status["commander"]
        result.update(mac=commander["mac"], seenAt=commander["seenAtText"], ageMinutes=minutes(status["age"]))
    if status["state"] == "unreadable":
        result.update(outcome=status["outcome"], problem=status["problem"])
    return result


ACTION_LABELS = {"open": "見張りの Issue を立てた", "recover": "戻ったことをコメントした", "notified": "知らせ済み"}
DRY_RUN_LABELS = {"open": "見張りの Issue を立てる", "recover": "戻ったことをコメントする", "notified": "知らせ済み"}


def action_text(entry: dict, dry_run: bool) -> str:
    text = (DRY_RUN_LABELS if dry_run else ACTION_LABELS)[entry["action"]]
    if entry.get("closed"):
        text += "（閉じる）" if dry_run else "（閉じた）"
    if entry.get("number"):
        text += f"（#{entry['number']}）"
    return text


def describe(status: dict, done: list, dry_run: bool) -> str:
    text = f"司令塔: {STATE_LABELS[status['state']]}"
    if "commander" in status:
        text += f"（seenAt: {seen_cell(status)}）"
    if status["state"] == "unreadable":
        text += f"（{status['outcome']}: {status['problem']}）"
    actions = "、".join(action_text(entry, dry_run) for entry in done)
    if actions:
        text += f"。{actions}"
    writes = any(entry["action"] in ("open", "recover") for entry in done)
    return text + ("（--dry-run なので書いていません）" if dry_run and writes else "")


def cell(text: object) -> str:
    return str(text).replace("\n", " ").replace("|", "\\|")


def summary_markdown(result: dict) -> str:
    lines = ["### 司令塔の見張り", "", "| 項目 | 値 |", "| --- | --- |",
             f"| 様子 | {cell(STATE_LABELS[result['state']])} |"]
    if result.get("seenAt"):
        lines += [f"| 最後の `seenAt` | {cell(result['seenAt'])}（{relative_text(result['ageMinutes'])}） |",
                  f"| Mac | `{cell(result['mac'])}` |"]
    if result.get("problem"):
        lines.append(f"| 読めない理由 | {cell(result['outcome'])}: {cell(result['problem'])} |")
    actions = []
    for entry in result["actions"]:
        text = action_text(entry, result["dryRun"])
        actions.append(f"[{text}]({entry['url']})" if entry.get("url") else text)
    heading = "すること（--dry-run なので書いていない）" if result["dryRun"] else "したこと"
    lines += [f"| {heading} | {cell('、'.join(actions) or 'なし')} |",
              f"| 確かめた時刻 | {result['checkedAt']}（{result['staleAfterMinutes']} 分より古ければ止まったとみなす） |"]
    return "\n".join(lines) + "\n"


def command_check(args: argparse.Namespace, runner: Runner | None = None, now: datetime | None = None) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}", args.repo):
        raise UsageError(f"--repo は owner/name の形で指定してください（{args.repo}）")
    github = GitHub(args.repo, runner or run_command)
    result = check(args.repo, github, now or datetime.now(timezone.utc), dry_run=args.dry_run)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(summary_markdown(result))
    return result


# MARK: render-workflow


def git(root: Path, *args: str) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, encoding="utf-8")


def resolve_ref(root: Path, ref: str) -> str:
    """`ref` をコミットの SHA にし、Tools/commander_watch.py があってリモートのブランチに入っているかを確かめる"""
    if ref.startswith("-"):
        raise UsageError(f"--ref にはコミットかブランチを指定してください（{ref}）")
    resolved = git(root, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}")
    sha = resolved.stdout.strip()
    if resolved.returncode != 0 or not SHA.fullmatch(sha):
        raise Failure(f"{ref} をコミットとして読めません（先に git fetch してください）")
    if git(root, "cat-file", "-e", f"{sha}:{SCRIPT_PATH}").returncode != 0:
        raise Failure(f"{sha[:12]} に {SCRIPT_PATH} がありません")
    remote = git(root, "branch", "-r", "--contains", sha)
    if remote.returncode != 0 or not remote.stdout.strip():
        raise Failure(f"{sha[:12]} はリモートのブランチに入っていません（push してから、リモートのブランチのコミットを指定してください）")
    return sha


def render_workflow(template: str, sha: str) -> str:
    if not SHA.fullmatch(sha):
        raise UsageError(f"判定の版はコミットの SHA（40 桁）で指定してください（{sha}）")
    if template.count(WORKFLOW_REF_PLACEHOLDER) != 1:
        raise Failure(f"雛形に {WORKFLOW_REF_PLACEHOLDER} がちょうど 1 つありません")
    return template.replace(WORKFLOW_REF_PLACEHOLDER, sha)


def command_render_workflow(args: argparse.Namespace) -> dict:
    root = Path(args.root)
    sha = resolve_ref(root, args.ref)
    # 作業ツリーではなく、判定と同じコミットの雛形を使う
    shown = git(root, "show", f"{sha}:{WORKFLOW_TEMPLATE}")
    if shown.returncode != 0:
        raise Failure(f"{sha[:12]} に {WORKFLOW_TEMPLATE} がありません")
    Path(args.output).write_text(render_workflow(shown.stdout, sha), encoding="utf-8")
    return {"ok": True, "sha": sha, "output": args.output,
            "messages": [f"{args.output} に書きました（判定の版: {sha[:12]}）"]}


# MARK: 入口


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str):  # type: ignore[override]
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True, parser_class=JsonArgumentParser)

    run = commands.add_parser("check", help="司令塔の生きている印を確かめ、見張りの Issue を立てる・閉じる")
    run.add_argument("--repo", required=True, help="状態リポジトリの owner/name")
    run.add_argument("--summary", help="Job Summary の Markdown を足すファイル")
    run.add_argument("--dry-run", action="store_true", help="Issue を立てたり閉じたりせず、することだけを出す")

    render = commands.add_parser("render-workflow", help="状態リポジトリに入れるワークフローを書く")
    render.add_argument("--ref", required=True, help="判定の版にする ask-hub-apple のコミット（origin/renewal など。SHA に直して書く）")
    render.add_argument("--output", required=True, help="書き出すファイル（状態リポジトリの .github/workflows/commander-watch.yml）")
    render.add_argument("--root", default=str(ROOT), help="ask-hub-apple の checkout（既定はこのファイルの 1 つ上）")
    return parser


def emit(result: dict) -> None:
    for message in result.get("messages", []):
        print(message, file=sys.stderr)
    if result.get("error"):
        print(f"失敗: {result['error']}", file=sys.stderr)
    print(json.dumps(result, ensure_ascii=False, indent=2))


def main(argv: list | None = None, runner: Runner | None = None, now: datetime | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except UsageError as error:
        emit({"ok": False, "error": f"引数の誤り: {error}"})
        parser.print_usage(sys.stderr)
        return 2
    try:
        result = command_render_workflow(args) if args.command == "render-workflow" else command_check(args, runner, now)
    except UsageError as error:
        emit({"command": args.command, "ok": False, "error": f"引数の誤り: {error}"})
        return 2
    except Failure as error:
        emit({"command": args.command, "ok": False, "error": str(error)})
        return 1
    except Exception as error:  # noqa: BLE001  JSON を出さずに落ちない
        traceback.print_exc(file=sys.stderr)
        emit({"command": args.command, "ok": False, "error": f"{type(error).__name__}: {error}"})
        return 1
    emit({"command": args.command, **result})
    return 0


if __name__ == "__main__":
    sys.exit(main())
