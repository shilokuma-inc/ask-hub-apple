#!/usr/bin/env python3
"""定期実行（.github/workflows/release-sync.yml。Release/Sync）の処理（Discussion #605 の Q4・Q7）。

結果は JSON で標準出力に出す（ワークフローは jq で読む）。人に向けた説明は標準エラーにも出す。

    python3 Tools/release_sync.py targets                    # タグ v<v> の無い release/<v> の一覧（App Store Connect は呼ばない）
    python3 Tools/release_sync.py sync --versions 1.1.0 --repo owner/name \\
        --app-store-python <PyJWT を入れた python> [--platforms IOS,MAC_OS] [--summary <Markdown を足すファイル>]

- `targets`: `git ls-remote` で `release/<v>`（`MAJOR.MINOR.PATCH`）のうち、タグ `v<v>` の無いものを並べる（`release-finish/**` などは数えない）。
  形の違う `release/…` は `ignored` に入れて知らせる。`develop`（`--develop-ref`）の `MARKETING_VERSION` と同じで前の `v*` タグが無い
  （初回に同じバージョンで始めた）ときは、ビルドの取り違えの注意を `warnings` に出す
- `sync`: release ブランチ（バージョン）ごとに、
  1. `Tools/release_app_store.py attach-build`: 処理が終わったビルドがまだ紐付いていなければ紐付ける
  2. `Tools/release_app_store.py status`: 作ったプラットフォームすべてで配信済みか（必須のプラットフォームは必ず含める）
  3. 配信済みなら、Release/Finish（`release-finish.yml`）を `develop` で起動してよいかを確かめ（`finish_gate`）、起動する
  どれかのバージョンが失敗しても、ほかのバージョンは続ける。

Release/Finish を起動しないのは、run-name が `Release/Finish <v>` の run が実行中・待ち（二重に起動しない）・成功済み・失敗したとき
（失敗した後は人が原因を直して手で起動し直す。定期実行のたびに起動し直さない）と、取り込み待ちの PR（head `release-finish/<v>/pr-<main|develop>`）
か Issue（`【CHORE】release/<v> を <main|develop> に取り込めませんでした`。github-actions[bot] が作ったもの）が開いているとき。

GitHub は `gh`（`GH_TOKEN`）で読み、一覧はページングを最後までたどる（`gh api --paginate`）。
終了コード: 0 = すべて成功 / 1 = どれかが失敗（`ok: false`。ほかのバージョンの結果は残る）/ 2 = 引数の誤り。
どの終了コードでも、標準出力には JSON を 1 つ出す。外の依存は無い（標準ライブラリだけ。PyJWT は release_app_store.py の側で使う）。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import traceback
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_prepare import (  # noqa: E402
    RELEASE_VERSION,
    ROOT,
    XCCONFIG,
    Failure,
    JsonArgumentParser,
    UsageError,
    emit,
    git,
    marketing_version,
    remote_refs,
    version_key,
)

TOOLS = Path(__file__).resolve().parent

#: Release/Finish のワークフローと、起動する ref（Tools/ は develop のものを使う。docs/release.md の「リリース後作業」）
FINISH_WORKFLOW = "release-finish.yml"
FINISH_REF = "develop"

#: GITHUB_TOKEN で作った Issue の author
ACTIONS_BOT = "github-actions[bot]"

#: プラットフォームの表示名
PLATFORM_LABELS = {"IOS": "iOS", "MAC_OS": "macOS"}

#: コマンドを実行する関数（テストで差し替える）。引数のリストを受け取り、returncode・stdout・stderr を持つものを返す
Runner = Callable[[list], "subprocess.CompletedProcess[str]"]


def run_command(argv: list) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(argv, capture_output=True, text=True)


def first_lines(text: str, count: int = 2) -> str:
    lines = [line.strip() for line in (text or "").splitlines() if line.strip()]
    return " ".join(lines[:count]) or "理由はログを見てください"


# MARK: targets


def finish_titles(version: str) -> dict:
    """取り込み待ちの PR の head と、PR を作れなかったときの Issue のタイトル（Tools/release_finish_merge.sh と同じ）。"""
    branch = f"release/{version}"
    return {
        "heads": {f"release-finish/{version}/pr-{target}" for target in ("main", "develop")},
        "issues": {f"【CHORE】{branch} を {target} に取り込めませんでした" for target in ("main", "develop")},
    }


def find_targets(branches: list, tags: list, develop_version: str | None) -> dict:
    """タグの無い release ブランチ。branches は `release/` を除いた名前、tags はタグ名（`v` を含む）。"""
    versions, ignored, finished, warnings = [], [], [], []
    for name in branches:
        if not RELEASE_VERSION.match(name):
            ignored.append({"branch": f"release/{name}",
                            "reason": "名前が release/MAJOR.MINOR.PATCH の形ではないので見ません"})
        elif f"v{name}" in tags:
            finished.append(name)
        else:
            versions.append(name)
    versions.sort(key=version_key)
    finished.sort(key=version_key)

    released = any(version_key(tag[1:]) for tag in tags if tag.startswith("v"))
    for version in versions:
        if develop_version == version and not released:
            warnings.append(
                f"release/{version} は develop の MARKETING_VERSION と同じバージョンです（前の v* タグが無い初回）。"
                f"develop への push で上がったビルドも {version} になり、紐付け（attach-build）はアップロードの新しいものを選びます。"
                "審査に出す前に、紐付いたビルドが release ブランチから上がったもの（ビルド番号・アップロードの時刻）か確かめてください。"
            )

    messages = []
    if versions:
        messages.append("タグの無い release ブランチ: " + ", ".join(f"release/{v}" for v in versions))
    else:
        messages.append("タグの無い release ブランチはありません（何もしません）。")
    for item in ignored:
        messages.append(f"{item['branch']}: {item['reason']}")
    return {"ok": True, "versions": versions, "ignored": ignored, "finished": finished,
            "warnings": warnings, "messages": messages}


def command_targets(args: argparse.Namespace) -> dict:
    root = Path(args.root)
    branches, tags = remote_refs(root, args.remote)
    try:
        develop_version = marketing_version(git(root, "show", f"{args.develop_ref}:{XCCONFIG}"))
    except Failure:
        develop_version = None  # 読めなくても列挙は続ける（注意を出さないだけ）
    return find_targets(branches, tags, develop_version)


# MARK: Release/Finish を起動してよいか


def finish_gate(version: str, repo: str, runs: list, pulls: list, issues: list) -> dict:
    """Release/Finish を起動してよいか。`state` が `start` なら起動する。

    runs は release-finish.yml の run（`display_title`・`status`・`conclusion`・`html_url`）、pulls は開いた PR
    （`head`・`headRepo`・`html_url`）、issues は開いた Issue（`title`・`author`・`html_url`）。
    """
    title = f"Release/Finish {version}"
    mine = sorted((run for run in runs if run.get("display_title") == title),
                  key=lambda run: run.get("id") or 0, reverse=True)
    names = finish_titles(version)

    # completed 以外（queued・in_progress・waiting・requested・pending）は、まだ終わっていない run
    active = [run for run in mine if run.get("status") != "completed"]
    if active:
        return {"start": False, "state": "running", "url": active[0].get("html_url"),
                "message": f"{title} の run が実行中か待ちなので、起動しません（二重に起動しない）。"}

    # 取り込み待ちの PR は、このリポジトリのブランチ（書き込み権限のある人しか作れない）を head にしたものだけを見る
    waiting = [pull for pull in pulls if pull.get("head") in names["heads"] and pull.get("headRepo") == repo]
    # Issue は誰でも作れるので、Release/Finish（GITHUB_TOKEN）が作ったものだけを見る
    waiting += [issue for issue in issues if issue.get("title") in names["issues"] and issue.get("author") == ACTIONS_BOT]
    if waiting:
        urls = ", ".join(item.get("html_url") or "?" for item in waiting)
        return {"start": False, "state": "waiting-merge", "url": waiting[0].get("html_url"),
                "message": f"取り込み待ちの PR / Issue（{urls}）が開いているので、起動し直しません。"
                           "人が取り込んでから、Release/Finish を手で起動し直してください（docs/release.md の「取り込めなかったとき」）。"}

    succeeded = [run for run in mine if run.get("conclusion") == "success"]
    if succeeded:
        return {"start": False, "state": "finished", "url": succeeded[0].get("html_url"),
                "message": f"{title} の run は成功しています（タグ v{version} がまだ見えないだけなら、次の実行で対象から外れます）。"}

    if mine:
        latest = mine[0]
        return {"start": False, "state": "failed", "url": latest.get("html_url"),
                "message": f"{title} の run が {latest.get('conclusion') or '終わらず'} で止まっているので、起動し直しません。"
                           "Job Summary の理由を直してから、Release/Finish を手で起動し直してください（docs/release.md の「リリース後作業」の「失敗したとき」）。"}

    return {"start": True, "state": "start", "url": None, "message": f"{title} を起動します。"}


# MARK: sync


class GitHubReader:
    """gh で GitHub を読む。一覧は 1 回の sync で 1 度だけ読み、バージョンごとに使い回す。"""

    def __init__(self, repo: str, runner: Runner):
        self.repo = repo
        self.runner = runner
        self._cache: dict = {}

    def paginate(self, path: str, jq: str) -> list:
        if path in self._cache:
            return self._cache[path]
        completed = self.runner(["gh", "api", "--paginate", path, "--jq", jq])
        if completed.returncode != 0:
            if "404" in (completed.stderr or ""):
                raise Failure(f"{path} がありません（HTTP 404）: {first_lines(completed.stderr)}")
            raise Failure(f"GitHub を読めませんでした（{path}）: {first_lines(completed.stderr)}")
        items = []
        for line in completed.stdout.splitlines():
            if line.strip():
                try:
                    items.append(json.loads(line))
                except ValueError as error:
                    raise Failure(f"GitHub の応答を読めませんでした（{path}）: {error}") from error
        self._cache[path] = items
        return items

    def finish_runs(self) -> list:
        return self.paginate(
            f"repos/{self.repo}/actions/workflows/{FINISH_WORKFLOW}/runs?per_page=100",
            ".workflow_runs[] | {id, display_title, status, conclusion, html_url}")

    def open_pulls(self) -> list:
        return self.paginate(
            f"repos/{self.repo}/pulls?state=open&per_page=100",
            ".[] | {number, html_url, head: .head.ref, headRepo: .head.repo.full_name}")

    def open_issues(self) -> list:
        # issues の一覧には PR も入るので除く
        return self.paginate(
            f"repos/{self.repo}/issues?state=open&per_page=100",
            ".[] | select(.pull_request == null) | {number, title, html_url, author: .user.login}")


def app_store(runner: Runner, python: str, command: str, version: str, platforms: str) -> dict:
    """Tools/release_app_store.py を実行して JSON を返す。読めなければ ok: false。"""
    completed = runner([python, str(TOOLS / "release_app_store.py"), command, "--version", version,
                        "--platforms", platforms])
    try:
        result = json.loads(completed.stdout)
    except ValueError:
        return {"command": command, "ok": False, "platforms": {},
                "error": f"release_app_store.py {command} の結果を読めませんでした: {first_lines(completed.stderr)}"}
    if not isinstance(result, dict):
        return {"command": command, "ok": False, "platforms": {},
                "error": f"release_app_store.py {command} の結果が JSON のオブジェクトではありません"}
    return result


def sync_version(version: str, repo: str, reader: GitHubReader, runner: Runner, python: str,
                 platforms: str) -> dict:
    """1 つのバージョンの紐付け・配信の検知・Release/Finish の起動。失敗は結果に残し、例外にしない。"""
    entry: dict = {"version": version, "branch": f"release/{version}", "ok": True, "errors": []}

    attach = app_store(runner, python, "attach-build", version, platforms)
    entry["attach"] = attach
    if not attach.get("ok"):
        entry["errors"].append(f"ビルドの紐付け: {attach.get('error') or '失敗しました'}")

    # 紐付けが失敗しても（macOS だけの 409 など）、配信の検知は続ける
    status = app_store(runner, python, "status", version, platforms)
    entry["status"] = status
    if not status.get("ok"):
        entry["errors"].append(f"配信の状態: {status.get('error') or '失敗しました'}")
    entry["released"] = bool(status.get("ok") and status.get("released") is True)

    if not entry["released"]:
        entry["finish"] = {"state": "not-released", "start": False, "url": None,
                           "message": "まだ配信されていないので、Release/Finish は起動しません。"}
    else:
        try:
            gate = finish_gate(version, repo, reader.finish_runs(), reader.open_pulls(), reader.open_issues())
        except Failure as error:
            gate = {"state": "error", "start": False, "url": None,
                    "message": f"Release/Finish を起動してよいかを確かめられませんでした: {error}"}
            entry["errors"].append(gate["message"])
        if gate["start"]:
            completed = runner(["gh", "workflow", "run", FINISH_WORKFLOW, "--repo", repo, "--ref", FINISH_REF,
                                "-f", f"version={version}"])
            if completed.returncode == 0:
                gate = {**gate, "state": "started",
                        "message": f"配信を検知したので、Release/Finish {version} を {FINISH_REF} で起動しました。"}
            else:
                gate = {**gate, "state": "error",
                        "message": f"Release/Finish の起動に失敗しました: {first_lines(completed.stderr)}"}
                entry["errors"].append(gate["message"])
        entry["finish"] = gate

    entry["ok"] = not entry["errors"]
    return entry


def sync(versions: list, repo: str, runner: Runner, python: str, platforms: str) -> dict:
    reader = GitHubReader(repo, runner)
    releases = []
    for version in versions:
        try:
            releases.append(sync_version(version, repo, reader, runner, python, platforms))
        except Exception as error:  # noqa: BLE001  1 つのバージョンの思わぬ失敗で、ほかのバージョンを止めない
            traceback.print_exc(file=sys.stderr)
            releases.append({"version": version, "branch": f"release/{version}", "ok": False,
                             "errors": [f"{type(error).__name__}: {error}"], "attach": {}, "status": {},
                             "released": False,
                             "finish": {"state": "error", "start": False, "url": None, "message": str(error)}})
    messages = []
    for entry in releases:
        messages.append(f"{entry['branch']}: {entry['finish']['message']}")
        messages.extend(f"{entry['branch']}: {error}" for error in entry["errors"])
    failed = [entry["branch"] for entry in releases if not entry["ok"]]
    result = {"ok": not failed, "repo": repo, "platforms": platforms, "releases": releases,
              "started": [entry["version"] for entry in releases if entry["finish"]["state"] == "started"],
              "messages": messages}
    if failed:
        result["error"] = f"{', '.join(failed)} で失敗しました（ほかの release ブランチは続けました）"
    return result


# MARK: Job Summary


def cell(text: object) -> str:
    return str(text).replace("\n", " ").replace("|", "\\|")


ATTACH_LABELS = {
    "attached": "紐付けた", "already-attached": "紐付け済み", "waiting-for-build": "処理済みのビルド待ち",
    "locked": "審査中・配信済みなので触らない", "version-missing": "バージョンなし", "platform-missing": "プラットフォームなし",
    "blocked": "止まった", "error": "失敗",
}
STATUS_LABELS = {
    "released": "配信済み", "not-released": "まだ", "version-missing": "バージョンなし",
    "platform-missing": "プラットフォームなし", "blocked": "止まった", "error": "失敗",
}
FINISH_LABELS = {
    "started": "**起動した**", "not-released": "配信待ち", "running": "実行中の run があるので起動しない",
    "waiting-merge": "取り込み待ちの PR / Issue があるので起動し直さない", "finished": "成功した run がある",
    "failed": "失敗した run があるので起動し直さない", "error": "**失敗**",
}


def platform_cell(result: dict, labels: dict) -> str:
    platforms = result.get("platforms") or {}
    if not platforms:
        return "**失敗**" if result.get("ok") is False else "—"
    parts = []
    for platform, entry in platforms.items():
        label = labels.get(entry.get("status"), entry.get("status"))
        detail = []
        build = entry.get("build") or {}
        if entry.get("status") in ("attached", "already-attached") and build.get("buildNumber"):
            detail.append(f"ビルド {build['buildNumber']}")
        if entry.get("status") in ("not-released", "locked") and entry.get("state"):
            detail.append(str(entry["state"]))
        suffix = f"（{'・'.join(detail)}）" if detail else ""
        parts.append(f"{PLATFORM_LABELS.get(platform, platform)}: {label}{suffix}")
    return "<br>".join(cell(part) for part in parts)


def summary_markdown(result: dict) -> str:
    lines = ["| release ブランチ | ビルドの紐付け | 配信 | Release/Finish |", "| --- | --- | --- | --- |"]
    for entry in result["releases"]:
        finish = entry["finish"]
        label = FINISH_LABELS.get(finish["state"], finish["state"])
        if finish.get("url"):
            label += f"（[リンク]({finish['url']})）"
        lines.append(f"| `{entry['branch']}` | {platform_cell(entry.get('attach') or {}, ATTACH_LABELS)} | "
                     f"{platform_cell(entry.get('status') or {}, STATUS_LABELS)} | {cell(label)} |")
    lines.append("")
    for entry in result["releases"]:
        notes = [entry["finish"]["message"], *entry["errors"]]
        for source in (entry.get("attach") or {}, entry.get("status") or {}):
            for platform_entry in (source.get("platforms") or {}).values():
                if platform_entry.get("status") in ("error", "blocked", "platform-missing", "attached"):
                    notes.append(platform_entry.get("message", ""))
        for note in dict.fromkeys(note for note in notes if note):
            lines.append(f"- `{entry['branch']}`: {cell(note)}")
    return "\n".join(lines) + "\n"


def command_sync(args: argparse.Namespace, runner: Runner | None = None) -> dict:
    versions = [item.strip() for item in args.versions.split(",") if item.strip()]
    invalid = [item for item in versions if not RELEASE_VERSION.match(item)]
    if invalid:
        raise UsageError(f"バージョンは MAJOR.MINOR.PATCH の形で指定してください（{', '.join(invalid)}）")
    result = sync(versions, args.repo, runner or run_command, args.app_store_python, args.platforms)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(summary_markdown(result))
    return result


# MARK: 入口


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(ROOT), help="リポジトリのルート（既定はこのファイルの 1 つ上）")
    commands = parser.add_subparsers(dest="command", required=True, parser_class=JsonArgumentParser)

    targets = commands.add_parser("targets", help="タグの無い release ブランチを並べる")
    targets.add_argument("--remote", default="origin")
    targets.add_argument("--develop-ref", default="HEAD",
                         help="MARKETING_VERSION を読む develop（既定は作業ツリーの HEAD。ワークフローは develop を checkout する）")

    run = commands.add_parser("sync", help="release ブランチごとにビルドを紐付け、配信されたら Release/Finish を起動する")
    run.add_argument("--versions", required=True, help="カンマ区切りのバージョン（targets の versions）")
    run.add_argument("--repo", required=True, help="owner/name")
    run.add_argument("--app-store-python", default=sys.executable,
                     help="Tools/release_app_store.py を動かす python（PyJWT を入れた venv のもの）")
    run.add_argument("--platforms", default="IOS,MAC_OS", help="release_app_store.py の --platforms")
    run.add_argument("--summary", help="Job Summary の Markdown を足すファイル")
    return parser


COMMANDS = {"targets": command_targets, "sync": command_sync}


def main(argv: list | None = None, runner: Runner | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except UsageError as error:
        emit({"ok": False, "error": f"引数の誤り: {error}"})
        parser.print_usage(sys.stderr)
        return 2
    try:
        result = command_sync(args, runner) if args.command == "sync" else COMMANDS[args.command](args)
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
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
