#!/usr/bin/env python3
"""リリース準備（.github/workflows/release-prepare.yml）の、git とファイルの操作（Discussion #605 の Q2・Q5）。

結果は JSON で標準出力に出す（ワークフローは jq で読む）。人に向けた説明は標準エラーにも出す。

    python3 Tools/release_prepare.py check --version 1.1.0 [--resume]   # 始めてよいかを確かめる
    python3 Tools/release_prepare.py set-version --version 1.1.0         # MARKETING_VERSION を書き換える
    python3 Tools/release_prepare.py draft --version 1.1.0 --repo owner/name --output AppStore/whats-new-draft.json

- `check`: バージョンの形（MAJOR.MINOR.PATCH）・`release/<v>` と `v<v>` の有無・ほかの準備中の release ブランチ・
  `develop` の `MARKETING_VERSION` との大小を確かめる。`develop` と同じバージョンは、前の `v*` タグが 1 つも無い初回だけ
  通す（`sameVersion: true` と `warnings` を返す）。refs は `git ls-remote <remote>`、`MARKETING_VERSION` は
  `git show <develop-ref>:Configs/Project.xcconfig` で読む
- `set-version`: `Configs/Project.xcconfig` の `MARKETING_VERSION` を書き換える（同じなら何もしない）
- `draft`: 前の `v*` タグから `--head` までに `develop` に入った PR のタイトルで、最新情報の下書きを作る
  （形は docs/release.md の「最新情報の下書き」）。PR のタイトルは GitHub API（環境変数 `GH_TOKEN`）で読み、
  読めなければマージコミットのメッセージを使う

終了コード: 0 = 成功（`ok: true`）/ 1 = 失敗・始められない（`ok: false`。`error` に理由）/ 2 = 引数の誤り。
どの終了コードでも、標準出力には JSON を 1 つ出す。外の依存は無い（標準ライブラリだけ）。
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, NamedTuple

ROOT = Path(__file__).resolve().parent.parent

#: リリースのバージョンの形（ゴールの「既定の設計」）
RELEASE_VERSION = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")

XCCONFIG = "Configs/Project.xcconfig"
LANGUAGES_FILE = "AppStore/languages.json"
DRAFT_FILE = "AppStore/whats-new-draft.json"

#: 下書きの JSON の形の版。形を変えたら上げる（読む側: release-notes.yml・アプリ）
DRAFT_SCHEMA_VERSION = 1

#: 最新情報の上限（App Store Connect の whatsNew）
WHATS_NEW_LIMIT = 4000

#: 最新情報に載せる PR の種類（タイトルの【TYPE】）。種類の無いタイトルも載せる。
#: CI・ドキュメント・テスト・リファクタなど、使う人から見えない変更は載せない（一覧には `included: false` で残す）
USER_FACING_TYPES = {"FEAT", "FIX", "PERF"}

#: 載せる PR が 1 つも無いときの本文
FALLBACK_TEXT = "細かな改善と不具合の修正を行いました。"

#: 前のタグが無い（初めてのリリース）ときの本文。App Store は最初のバージョンに最新情報を出さない
INITIAL_TEXT = "はじめてのリリースです。"

MERGE_SUBJECT = re.compile(r"^Merge pull request #(\d+) from ([^/\s]+)/(\S+)")
TITLE_TYPE = re.compile(r"^【([A-Za-z]+)】\s*(.*)$")

GITHUB_API = "https://api.github.com"

#: 403 / 429 の `Retry-After` をこの秒数まで待って送り直す。長ければ API をあきらめてコミットのメッセージを使う
GITHUB_MAX_WAIT = 60
GITHUB_RETRIES = 3


class Failure(Exception):
    """始められない・続けられない（終了コード 1）。"""


class UsageError(Exception):
    """引数の誤り（終了コード 2）。"""


def version_key(version: str) -> tuple[int, int, int] | None:
    match = RELEASE_VERSION.match(version)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def git(root: Path, *args: str) -> str:
    completed = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if completed.returncode != 0:
        raise Failure(f"git {' '.join(args)} が失敗しました: {completed.stderr.strip()}")
    return completed.stdout


# MARK: check


def marketing_version(xcconfig_text: str) -> str | None:
    """xcconfig の `MARKETING_VERSION = x` の値（`//` のコメントは除く）。無ければ None。"""
    for line in xcconfig_text.splitlines():
        match = re.fullmatch(r"\s*MARKETING_VERSION\s*=\s*(.*?)\s*", line.split("//", 1)[0])
        if match:
            return match.group(1)
    return None


def same_version_warning(version: str) -> str:
    """初回に `develop` と同じバージョンで始めたときの注意（Job Summary に出す）。"""
    return (
        f"develop の MARKETING_VERSION と同じ {version} で始めます（前の v* タグが無い初回のため）。"
        f"develop への push で上がったビルドも release ブランチのビルドも {version} になり、App Store Connect では見分けられません。"
        "ビルドの紐付け（Release/Sync の attach-build）はアップロードの新しいものを選ぶので、"
        "審査に出す前に、紐付いたビルドが release ブランチから上がったもの（ビルド番号・アップロードの時刻）か確かめてください。"
    )


def check_release(version: str, develop_version: str | None, release_branches: list[str],
                  tags: list[str], resume: bool = False) -> dict:
    """リリース準備を始めてよいか。release_branches は `release/` を除いた名前、tags は `v` を含むタグ名。

    `develop` の `MARKETING_VERSION` と同じバージョンは、前の `v*` タグ（MAJOR.MINOR.PATCH の形のもの）が
    1 つも無い初回だけ通す（PR #627 の ask pr627-1 の回答 B）。2 回目以降は `develop` より大きい値だけ。
    """
    branch, tag = f"release/{version}", f"v{version}"
    released = [key for key in (version_key(name[1:]) for name in tags if name.startswith("v")) if key]
    same_version = develop_version == version
    result = {"ok": True, "version": version, "branch": branch, "tag": tag,
              "developVersion": develop_version, "resume": resume,
              "bumpVersion": not same_version, "sameVersion": False, "initial": not released,
              "messages": [], "warnings": []}

    if tag in tags:
        raise Failure(f"タグ {tag} がすでにあります（{version} はリリース済みです）。新しいバージョンを指定してください。")

    # タグの無い release ブランチは、準備中か審査中のリリース。App Store Connect の編集できるバージョンは
    # プラットフォームごとに 1 つなので、並べて準備すると前のリリースのバージョンを書き換えてしまう
    in_flight = sorted(name for name in release_branches if f"v{name}" not in tags and name != version)
    if in_flight:
        names = ", ".join(f"release/{name}" for name in in_flight)
        raise Failure(
            f"タグの無い release ブランチ（{names}）があります。前のリリースを終える（リリース後作業でタグを打つ）か、"
            "やめたリリースの release ブランチを消してから始めてください。"
        )

    if version in release_branches:
        if not resume:
            raise Failure(
                f"{branch} がすでにあります。途中で止まった準備を続けるときは resume をオンにして再実行してください"
                "（ブランチは作り直さず、App Store Connect のバージョンの用意とアップロードなどの起動だけを行います）。"
            )
        result["messages"].append(f"{branch} があるので、ブランチの作成を飛ばして続きから行います。")
        result["bumpVersion"] = False
        if same_version and not released:
            # 初回に同じバージョンで切った release ブランチの続き。紐付けの注意は resume でも出す
            result["sameVersion"] = True
            result["warnings"].append(same_version_warning(version))
        return result
    if resume:
        raise Failure(f"resume を指定しましたが {branch} がありません。resume をオフにして実行してください。")

    target = version_key(version)
    develop_key = version_key(develop_version or "")
    if develop_key is None:
        raise Failure(f"develop の {XCCONFIG} の MARKETING_VERSION（{develop_version}）が MAJOR.MINOR.PATCH の形ではありません。")
    if target == develop_key and not released:
        # 初回（前の v* タグが無い）だけ、develop の MARKETING_VERSION のまま出せる（App Store の最初のバージョンを 1.0.0 にするため）。
        # ビルドはバージョンとプラットフォームだけで選ぶので、develop のビルドを紐付けうる。Summary で注意を出す
        result["sameVersion"] = True
        result["warnings"].append(same_version_warning(version))
    elif target <= develop_key:  # type: ignore[operator]
        # ビルドはバージョンとプラットフォームだけで選ぶので、同じバージョンだと develop のビルドを紐付けうる
        reason = "前のリリースのタグがあるので、同じバージョンは使えません。" if target == develop_key else ""
        raise Failure(
            f"{version} は develop の MARKETING_VERSION（{develop_version}）より大きくしてください。{reason}"
            "同じバージョンにすると、develop への push で上がったビルドと release ブランチのビルドを App Store Connect で見分けられません。"
        )
    if released and target <= max(released):
        latest = ".".join(str(part) for part in max(released))
        raise Failure(f"{version} はリリース済みの最新のバージョン（v{latest}）より大きくしてください。")

    if result["bumpVersion"]:
        result["messages"].append(f"release ブランチで MARKETING_VERSION を {develop_version} から {version} に書き換えます。")
    return result


def remote_refs(root: Path, remote: str) -> tuple[list[str], list[str]]:
    """リモートの release ブランチ（`release/` を除いた名前）とタグの一覧。"""
    branches, tags = [], []
    for line in git(root, "ls-remote", "--heads", "--tags", remote).splitlines():
        ref = line.split("\t", 1)[-1]
        if ref.endswith("^{}"):
            continue
        if ref.startswith("refs/heads/release/"):
            branches.append(ref[len("refs/heads/release/"):])
        elif ref.startswith("refs/tags/"):
            tags.append(ref[len("refs/tags/"):])
    return branches, tags


def command_check(args: argparse.Namespace) -> dict:
    root = Path(args.root)
    develop_text = git(root, "show", f"{args.develop_ref}:{XCCONFIG}")
    branches, tags = remote_refs(root, args.remote)
    return check_release(args.version, marketing_version(develop_text), branches, tags, args.resume)


# MARK: set-version


def set_marketing_version(path: Path, version: str) -> dict:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r"^(\s*MARKETING_VERSION\s*=\s*)([^\s/]+)(.*)$", re.MULTILINE)
    matches = pattern.findall(text)
    if len(matches) != 1:
        raise Failure(f"{path.name} に MARKETING_VERSION の行が 1 つではありません（{len(matches)} 行）。")
    previous = matches[0][1]
    if previous != version:
        path.write_text(pattern.sub(lambda m: f"{m.group(1)}{version}{m.group(3)}", text), encoding="utf-8")
    return {"ok": True, "version": version, "previous": previous, "changed": previous != version,
            "messages": [f"MARKETING_VERSION: {previous} → {version}" if previous != version
                         else f"MARKETING_VERSION はすでに {version} です。"]}


def command_set_version(args: argparse.Namespace) -> dict:
    return set_marketing_version(Path(args.root) / XCCONFIG, args.version)


# MARK: draft


class Merge(NamedTuple):
    sha: str
    parents: list[str]
    number: int
    head_ref: str
    #: マージコミットの本文の 1 行目（GitHub の既定では PR のタイトル）
    title: str
    date: str


def merges(root: Path, revision_range: list[str]) -> list[Merge]:
    """first-parent でたどった PR のマージコミット（新しい順）。"""
    out = git(root, "log", "--first-parent", "--merges", "--format=%H%x00%P%x00%cI%x00%s%x00%b%x1e",
              *revision_range, "--")
    found = []
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, parents, date, subject, body = (record.split("\x00") + [""] * 5)[:5]
        match = MERGE_SUBJECT.match(subject)
        if not match:  # develop の取り込み（Merge branch …）などは PR ではない
            continue
        title = next((line.strip() for line in body.splitlines() if line.strip()), "")
        found.append(Merge(sha, parents.split(), int(match.group(1)), match.group(3), title, date))
    return found


def previous_tag(root: Path, version: str) -> str | None:
    """`version` より前の `v*` タグのうち、バージョンが最も大きいもの。"""
    target = version_key(version)
    candidates = []
    for name in git(root, "tag", "--list", "v*").split():
        key = version_key(name[1:])
        if key is not None and target is not None and key < target:
            candidates.append((key, name))
    return max(candidates)[1] if candidates else None


class GitHub:
    """PR のタイトルを読むだけの、最小限の GitHub REST API のクライアント。"""

    def __init__(self, repo: str, token: str | None, urlopen: Callable | None = None,
                 sleep: Callable[[float], None] | None = None):
        self.repo = repo
        self.token = token
        self._urlopen = urlopen or urllib.request.urlopen
        self._sleep = sleep or time.sleep
        #: レート制限などで読めなくなったら、それ以降は API を呼ばない
        self.disabled_reason: str | None = None if token else "GH_TOKEN がありません"

    def pull_request(self, number: int) -> dict | None:
        if self.disabled_reason:
            return None
        url = f"{GITHUB_API}/repos/{self.repo}/pulls/{number}"
        for attempt in range(GITHUB_RETRIES + 1):
            request = urllib.request.Request(url, headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
            })
            try:
                with self._urlopen(request, timeout=30) as response:
                    return json.loads(response.read())
            except urllib.error.HTTPError as error:
                if error.code in (403, 429):
                    wait = error.headers.get("Retry-After") if error.headers else None
                    remaining = error.headers.get("X-RateLimit-Remaining") if error.headers else None
                    if wait is not None and wait.isdigit() and int(wait) <= GITHUB_MAX_WAIT and attempt < GITHUB_RETRIES:
                        self._sleep(float(wait))
                        continue
                    if wait is not None or remaining == "0" or error.code == 429:
                        self.disabled_reason = f"GitHub API のレート制限（{error.code}）"
                        return None
                if error.code == 404:
                    return None
                self.disabled_reason = f"GitHub API が {error.code} を返しました"
                return None
            except (urllib.error.URLError, OSError, ValueError) as error:
                self.disabled_reason = f"GitHub API を読めません（{error}）"
                return None
        self.disabled_reason = "GitHub API のレート制限（再試行の上限）"
        return None


def split_title(raw: str) -> tuple[str | None, str]:
    """`【FEAT】タイトル` → ("FEAT", "タイトル")。【TYPE】が無ければ (None, そのまま)。"""
    match = TITLE_TYPE.match(raw.strip())
    if not match:
        return None, raw.strip()
    return match.group(1).upper(), match.group(2).strip()


def collect_pull_requests(root: Path, base: str | None, head: str) -> list[tuple[Merge, int | None]]:
    """`develop` に入った PR を古い順に。epic の PR は中の子 PR に開く（(子のマージ, epic の PR 番号)）。"""
    revision_range = [head] if base is None else [f"{base}..{head}"]
    collected: list[tuple[Merge, int | None]] = []
    for merge in merges(root, revision_range):
        if merge.head_ref.startswith("release/"):
            continue  # リリース後作業の release → develop の取り込み
        if merge.head_ref.startswith("epic/") and len(merge.parents) == 2:
            # epic → develop の PR のタイトルは「epic/xxx を develop に取り込む」なので、中の子 PR を載せる
            children = [child for child in merges(root, [f"{merge.parents[0]}..{merge.parents[1]}"])
                        if not child.head_ref.startswith(("epic/", "release/"))]
            collected.extend((child, merge.number) for child in children)
            continue
        collected.append((merge, None))
    seen: set[int] = set()
    unique = []
    for merge, epic in reversed(collected):
        if merge.number not in seen:
            seen.add(merge.number)
            unique.append((merge, epic))
    return unique


def whats_new_text(titles: list[str], limit: int = WHATS_NEW_LIMIT) -> tuple[str, int]:
    """箇条書きの本文と、上限に収まらず省いた件数。"""
    if not titles:
        return FALLBACK_TEXT, 0
    lines: list[str] = []
    for index, title in enumerate(titles):
        candidate = "\n".join([*lines, f"・{title}"])
        rest = len(titles) - index - 1
        suffix = f"\n・ほか {rest} 件" if rest else ""
        if len(candidate) + len(suffix) > limit:
            omitted = len(titles) - index
            return "\n".join([*lines, f"・ほか {omitted} 件"]), omitted
        lines.append(f"・{title}")
    return "\n".join(lines), 0


def language_codes(root: Path) -> list[str]:
    entries = json.loads((root / LANGUAGES_FILE).read_text(encoding="utf-8"))["languages"]
    return [entry["language"] for entry in entries]


def build_draft(root: Path, version: str, repo: str, head: str, github: GitHub,
                now: datetime.datetime | None = None) -> dict:
    base = previous_tag(root, version)
    head_sha = git(root, "rev-parse", head).strip()
    languages = language_codes(root)
    generated_at = (now or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y-%m-%dT%H:%M:%SZ")
    draft: dict = {
        "schemaVersion": DRAFT_SCHEMA_VERSION,
        "version": version,
        "generatedAt": generated_at,
        "base": None,
        "head": {"ref": head, "sha": head_sha},
        "initial": base is None,
        "whatsNew": {},
        "omitted": 0,
        "pullRequests": [],
        "messages": [],
    }
    if base is None:
        # App Store は最初のバージョンに最新情報を出さないので、開発の履歴全体を並べない
        draft["whatsNew"] = {language: INITIAL_TEXT for language in languages}
        draft["messages"].append("前の v* タグが無いので、初めてのリリースの本文にしました。")
        return draft

    draft["base"] = {"tag": base, "sha": git(root, "rev-parse", f"{base}^{{commit}}").strip()}
    titles = []
    for merge, epic in collect_pull_requests(root, base, head):
        pull = github.pull_request(merge.number)
        raw_title = (pull or {}).get("title") or merge.title or f"#{merge.number}"
        kind, title = split_title(raw_title)
        included = kind is None or kind in USER_FACING_TYPES
        draft["pullRequests"].append({
            "number": merge.number,
            "title": title,
            "type": kind,
            "url": (pull or {}).get("html_url") or f"https://github.com/{repo}/pull/{merge.number}",
            "mergedAt": (pull or {}).get("merged_at") or merge.date,
            "epic": epic,
            "included": included,
        })
        if included:
            titles.append(title)
    if github.disabled_reason:
        draft["messages"].append(f"PR のタイトルの一部はマージコミットのメッセージから読みました（{github.disabled_reason}）。")
    text, omitted = whats_new_text(titles)
    draft["whatsNew"] = {language: text for language in languages}
    draft["omitted"] = omitted
    draft["messages"].append(
        f"{base} から {len(draft['pullRequests'])} 件の PR を読み、{len(titles)} 件を最新情報に載せました。"
    )
    return draft


def command_draft(args: argparse.Namespace, urlopen: Callable | None = None) -> dict:
    root = Path(args.root)
    github = GitHub(args.repo, os.environ.get("GH_TOKEN") or None, urlopen=urlopen)
    draft = build_draft(root, args.version, args.repo, args.head, github)
    output = root / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(draft, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"ok": True, "version": args.version, "output": args.output, "base": draft["base"],
            "initial": draft["initial"], "pullRequests": len(draft["pullRequests"]),
            "included": sum(1 for pull in draft["pullRequests"] if pull["included"]),
            "omitted": draft["omitted"], "messages": draft["messages"]}


# MARK: 入口


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str):  # type: ignore[override]
        raise UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(ROOT), help="リポジトリのルート（既定はこのファイルの 1 つ上）")
    commands = parser.add_subparsers(dest="command", required=True, parser_class=JsonArgumentParser)

    check = commands.add_parser("check", help="リリース準備を始めてよいかを確かめる")
    check.add_argument("--version", required=True)
    check.add_argument("--resume", action="store_true", help="release ブランチがあれば、続きから行う")
    check.add_argument("--remote", default="origin")
    check.add_argument("--develop-ref", default="origin/develop")

    set_version = commands.add_parser("set-version", help=f"{XCCONFIG} の MARKETING_VERSION を書き換える")
    set_version.add_argument("--version", required=True)

    draft = commands.add_parser("draft", help="最新情報の下書きを作る")
    draft.add_argument("--version", required=True)
    draft.add_argument("--repo", required=True, help="owner/name")
    draft.add_argument("--head", default="HEAD", help="下書きに含める最後のコミット（既定 HEAD）")
    draft.add_argument("--output", default=DRAFT_FILE, help=f"ルートからの出力先（既定 {DRAFT_FILE}）")
    return parser


COMMANDS = {"check": command_check, "set-version": command_set_version, "draft": command_draft}


def emit(result: dict) -> None:
    for message in result.get("messages", []):
        print(message, file=sys.stderr)
    for warning in result.get("warnings", []):
        print(f"注意: {warning}", file=sys.stderr)
    if result.get("error"):
        print(f"失敗: {result['error']}", file=sys.stderr)
    print(json.dumps(result, ensure_ascii=False, indent=2))


def main(argv: list[str] | None = None, urlopen: Callable | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except UsageError as error:
        emit({"ok": False, "error": f"引数の誤り: {error}"})
        parser.print_usage(sys.stderr)
        return 2
    failure = {"command": args.command, "ok": False, "version": args.version}
    if not RELEASE_VERSION.match(args.version):
        emit({**failure, "error": f"バージョンは MAJOR.MINOR.PATCH の形で指定してください（{args.version}）"})
        return 2
    try:
        if args.command == "draft":
            result = command_draft(args, urlopen=urlopen)
        else:
            result = COMMANDS[args.command](args)
    except Failure as error:
        emit({**failure, "error": str(error)})
        return 1
    except Exception as error:  # noqa: BLE001  JSON を出さずに落ちない
        traceback.print_exc(file=sys.stderr)
        emit({**failure, "error": f"{type(error).__name__}: {error}"})
        return 1
    emit({"command": args.command, **result})
    return 0


if __name__ == "__main__":
    sys.exit(main())
