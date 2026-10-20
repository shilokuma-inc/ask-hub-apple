#!/usr/bin/env python3
"""リリース後作業（.github/workflows/release-finish.yml）の、git とファイルの読み取り（Discussion #605 の Q6・Q7）。

結果は JSON で標準出力に出す（ワークフローは jq で読む）。人に向けた説明は標準エラーにも出す。
ネットワークには出ない（refs はワークフローが先に fetch しておく）。

    python3 Tools/release_finish.py check --version 1.1.0            # 何が済んでいて、何をするかを確かめる
    python3 Tools/release_finish.py tag-target --version 1.1.0       # v<v> を打つ main のコミット
    python3 Tools/release_finish.py --root release notes --version 1.1.0 --repo owner/name  # GitHub Release の本文
    python3 Tools/release_finish.py --root develop develop-version --version 1.1.0          # 取り込んだ後の develop のバージョン

- `check`: `<remote>/release/<v>` があること、`<remote>/main`・`<remote>/develop`・`v<v>` のタグにどこまで入っているか
  （`create` / `merge` / `done`）、release ブランチにしかないコミット（`<remote>/develop..release`）に AI 帰属行が無いことを確かめる。
  タグがあっても、release の先頭を含んでいれば再実行とみなし、残りの作業だけを返す
- `tag-target`: `main` の first-parent をたどり、release の先頭を初めて含むコミット（release を取り込んだマージコミット。
  初回に release の先頭から `main` を作ったときはその先頭）
- `notes`: `--root`（release ブランチの作業ツリー）の確定した最新情報（`AppStore/metadata/<言語>.json` の `whatsNew` で
  `version` が `<v>`）から本文を作る。確定していなければ下書き（`AppStore/whats-new-draft.json`）、どちらも無ければ前のタグからの PR の一覧
- `develop-version`: `--root`（release を取り込んだ `develop` の作業ツリー）の `MARKETING_VERSION` が `<v>` 以下なら、
  次のパッチ（`1.1.0` → `1.1.1`）に書き換える。配信を終えたバージョンのままだと、`develop` への push の Upload が
  閉じたバージョンに上げようとして失敗するため（docs/release.md の「リリース後作業」）

終了コード: 0 = 成功（`ok: true`）/ 1 = 失敗・続けられない（`ok: false`。`error` に理由）/ 2 = 引数の誤り。
どの終了コードでも、標準出力には JSON を 1 つ出す。外の依存は無い（標準ライブラリだけ）。
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_prepare import (  # noqa: E402
    DRAFT_FILE,
    FALLBACK_TEXT,
    RELEASE_VERSION,
    ROOT,
    XCCONFIG,
    Failure,
    JsonArgumentParser,
    UsageError,
    collect_pull_requests,
    emit,
    git,
    language_codes,
    marketing_version,
    previous_tag,
    set_marketing_version,
    split_title,
    version_key,
)
from release_notes import METADATA_DIR  # noqa: E402

#: no-ai-attribution.yml と同じ検査（m: 行頭の ^ を各行に効かせる / i: 大文字小文字を区別しない）
AI_ATTRIBUTION = re.compile(r"^Co-Authored-By:|Generated with \[Claude Code\]|noreply@anthropic\.com",
                            re.IGNORECASE | re.MULTILINE)

#: AI 帰属行のあるコミットを、エラーの文にいくつまで並べるか
MAX_LISTED = 10


# MARK: git の読み取り


def resolve(root: Path, ref: str) -> str | None:
    """ref のコミットの SHA。無ければ None。"""
    completed = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                               cwd=root, capture_output=True, text=True)
    return completed.stdout.strip() if completed.returncode == 0 else None


def is_ancestor(root: Path, ancestor: str, descendant: str) -> bool:
    completed = subprocess.run(["git", "merge-base", "--is-ancestor", ancestor, descendant],
                               cwd=root, capture_output=True, text=True)
    if completed.returncode not in (0, 1):
        raise Failure(f"git merge-base --is-ancestor が失敗しました: {completed.stderr.strip()}")
    return completed.returncode == 0


def attribution_findings(root: Path, base: str, head: str) -> list[str]:
    """`base..head` のコミットのうち、メッセージに AI 帰属行があるものの SHA（古い順）。"""
    out = git(root, "log", "--reverse", "--format=%H%x00%B%x1e", f"{base}..{head}", "--")
    found = []
    for record in out.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, _, message = record.partition("\x00")
        if AI_ATTRIBUTION.search(message):
            found.append(sha)
    return found


# MARK: check


def check_finish(root: Path, version: str, remote: str = "origin") -> dict:
    """何が済んでいて、何をするか。済んだものは飛ばすので、途中で止まった run を同じバージョンで起動し直せる。"""
    branch, tag = f"release/{version}", f"v{version}"
    release = resolve(root, f"refs/remotes/{remote}/{branch}")
    if release is None:
        raise Failure(f"{branch} がありません。バージョンの打ち間違いか、release ブランチを消していないかを確かめてください。")
    develop = resolve(root, f"refs/remotes/{remote}/develop")
    if develop is None:
        raise Failure("develop がありません。")
    main = resolve(root, f"refs/remotes/{remote}/main")
    tagged = resolve(root, f"refs/tags/{tag}")

    if main is None:
        main_state = "create"
    elif is_ancestor(root, release, main):
        main_state = "done"
    else:
        main_state = "merge"
    develop_state = "done" if is_ancestor(root, release, develop) else "merge"

    if tagged is None:
        tag_state = "create"
    elif not is_ancestor(root, release, tagged):
        raise Failure(f"タグ {tag} がありますが、{branch} の先頭（{release[:7]}）を含みません。"
                      "タグの打ち間違いか、タグを打った後に release ブランチが進んでいます。人が確かめてください。")
    elif main_state != "done":
        raise Failure(f"タグ {tag} はありますが、{branch} が main に入っていません。人が確かめてください。")
    else:
        tag_state = "done"

    # release ブランチにしかないコミット（develop の PR の検査を通っていないもの）だけを見る。
    # develop に入ったコミットは PR の No AI Attribution を通っている（初回の main は develop の全履歴を含むので、全部は見ない）
    findings = attribution_findings(root, develop, release)
    if findings:
        listed = ", ".join(sha[:7] for sha in findings[:MAX_LISTED])
        more = f" ほか {len(findings) - MAX_LISTED} 件" if len(findings) > MAX_LISTED else ""
        raise Failure(f"{branch} のコミットのメッセージに AI 帰属行があります（{listed}{more}）。"
                      "release ブランチで直してから起動し直してください。")

    labels = {"create": "作る", "merge": "マージコミットで取り込む", "done": "済み"}
    messages = [
        f"{branch} の先頭は {release[:7]} です。",
        f"main: {'release の先頭から' if main_state == 'create' else ''}{labels[main_state]}",
        f"タグ {tag}: {'打つ' if tag_state == 'create' else '済み'}",
        f"develop: {labels[develop_state]}",
    ]
    return {
        "ok": True, "version": version, "branch": branch, "tag": tag,
        "releaseSha": release, "mainSha": main, "developSha": develop, "tagSha": tagged,
        "main": main_state, "develop": develop_state, "tagState": tag_state,
        "initial": main is None,
        "pending": main_state != "done" or develop_state != "done" or tag_state != "done",
        "messages": messages,
    }


def command_check(args: argparse.Namespace) -> dict:
    return check_finish(Path(args.root), args.version, args.remote)


# MARK: tag-target


def tag_target(root: Path, release: str, main: str) -> str:
    """main の first-parent のうち、release の先頭を初めて含むコミット。"""
    # 新しい側からたどり、release の先頭を含まなくなる直前のコミットを選ぶ（初回の main は develop の全履歴を持つので、
    # 古い側からたどると取り込みまでの全コミットで merge-base を呼ぶことになる）
    found = None
    for sha in git(root, "rev-list", "--first-parent", main).split():
        if sha == release:
            return sha
        if not is_ancestor(root, release, sha):
            break
        found = sha
    if found is None:
        raise Failure(f"main に release の先頭（{release[:7]}）を含むコミットがありません。")
    return found


def command_tag_target(args: argparse.Namespace) -> dict:
    root = Path(args.root)
    branch = f"release/{args.version}"
    release = resolve(root, args.release_ref or f"refs/remotes/{args.remote}/{branch}")
    main = resolve(root, args.main_ref or f"refs/remotes/{args.remote}/main")
    if release is None or main is None:
        raise Failure(f"{branch} か main がありません。")
    target = tag_target(root, release, main)
    return {"ok": True, "version": args.version, "target": target,
            "messages": [f"v{args.version} は main の {target[:7]} に打ちます。"]}


# MARK: notes


def confirmed_whats_new(root: Path, version: str, languages: list[str]) -> dict[str, str] | None:
    """すべての言語で `whatsNew.version` が version なら、言語 → 本文。1 つでも違えば None。"""
    texts = {}
    for language in languages:
        path = root / METADATA_DIR / f"{language}.json"
        try:
            whats_new = json.loads(path.read_text(encoding="utf-8")).get("whatsNew")
        except (OSError, ValueError, AttributeError):
            return None
        if not isinstance(whats_new, dict) or whats_new.get("version") != version:
            return None
        text = whats_new.get("text")
        if not isinstance(text, str) or not text.strip():
            return None
        texts[language] = text.strip()
    return texts


def draft_whats_new(root: Path, version: str, languages: list[str]) -> dict[str, str] | None:
    """下書きがこのバージョンのもので、すべての言語に本文があれば、言語 → 本文。"""
    try:
        draft = json.loads((root / DRAFT_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(draft, dict) or draft.get("version") != version or not isinstance(draft.get("whatsNew"), dict):
        return None
    texts = {}
    for language in languages:
        text = draft["whatsNew"].get(language)
        if not isinstance(text, str) or not text.strip():
            return None
        texts[language] = text.strip()
    return texts


def pull_request_list(root: Path, version: str) -> str:
    """前のタグから release の先頭までに develop に入った PR の一覧（【TYPE】を外したタイトル）。"""
    base = previous_tag(root, version)
    lines = []
    for merge, _ in collect_pull_requests(root, base, "HEAD"):
        _, title = split_title(merge.title or f"#{merge.number}")
        lines.append(f"- {title} (#{merge.number})")
    return "\n".join(lines) if lines else FALLBACK_TEXT


def release_body(root: Path, version: str, repo: str) -> dict:
    languages = language_codes(root)
    texts = confirmed_whats_new(root, version, languages)
    source = "whatsNew"
    if texts is None:
        texts = draft_whats_new(root, version, languages)
        source = "draft"
    if texts is None:
        source = "pullRequests"
        body = pull_request_list(root, version)
    elif len(texts) == 1:
        body = next(iter(texts.values()))
    else:
        body = "\n\n".join(f"### {language}\n\n{text}" for language, text in texts.items())

    notes = {
        "whatsNew": "AppStore/metadata の確定した最新情報から作りました。",
        "draft": f"最新情報が確定していなかったので、下書き（{DRAFT_FILE}）から作りました。",
        "pullRequests": "最新情報の確定も下書きも無かったので、PR の一覧から作りました。",
    }
    if source == "draft":
        body += "\n\n> 最新情報が確定する前の下書きから作った本文です。"
    base = previous_tag(root, version)
    if base:
        body += f"\n\n**変更の一覧**: https://github.com/{repo}/compare/{base}...v{version}"
    return {"ok": True, "version": version, "source": source, "previousTag": base, "body": body + "\n",
            "messages": [notes[source]]}


def command_notes(args: argparse.Namespace) -> dict:
    return release_body(Path(args.root), args.version, args.repo)


# MARK: develop-version


def next_patch(version: str) -> str:
    major, minor, patch = version_key(version)  # type: ignore[misc]
    return f"{major}.{minor}.{patch + 1}"


def develop_version(root: Path, version: str) -> dict:
    """取り込んだ後の develop の MARKETING_VERSION が version 以下なら、次のパッチにする。"""
    path = root / XCCONFIG
    current = marketing_version(path.read_text(encoding="utf-8"))
    current_key = version_key(current or "")
    if current_key is None:
        raise Failure(f"{XCCONFIG} の MARKETING_VERSION（{current}）が MAJOR.MINOR.PATCH の形ではありません。")
    if current_key > version_key(version):  # type: ignore[operator]
        return {"ok": True, "version": current, "previous": current, "changed": False,
                "messages": [f"develop の MARKETING_VERSION（{current}）は {version} より大きいので変えません。"]}
    result = set_marketing_version(path, next_patch(version))
    result["messages"] = [f"develop の MARKETING_VERSION を {result['previous']} から {result['version']} にします"
                          f"（配信した {version} のままだと develop の Upload が失敗するため）。"]
    return result


def command_develop_version(args: argparse.Namespace) -> dict:
    return develop_version(Path(args.root), args.version)


# MARK: 入口


def build_parser() -> argparse.ArgumentParser:
    parser = JsonArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(ROOT), help="リポジトリのルート（既定はこのファイルの 1 つ上）")
    commands = parser.add_subparsers(dest="command", required=True, parser_class=JsonArgumentParser)

    check = commands.add_parser("check", help="何が済んでいて、何をするかを確かめる")
    check.add_argument("--version", required=True)
    check.add_argument("--remote", default="origin")

    target = commands.add_parser("tag-target", help="v<v> を打つ main のコミット")
    target.add_argument("--version", required=True)
    target.add_argument("--remote", default="origin")
    target.add_argument("--release-ref", help="release の先頭（既定 <remote>/release/<v>）")
    target.add_argument("--main-ref", help="main（既定 <remote>/main）")

    notes = commands.add_parser("notes", help="GitHub Release の本文を作る")
    notes.add_argument("--version", required=True)
    notes.add_argument("--repo", required=True, help="owner/name")

    develop = commands.add_parser("develop-version", help="取り込んだ後の develop の MARKETING_VERSION を次のパッチにする")
    develop.add_argument("--version", required=True)
    return parser


COMMANDS = {"check": command_check, "tag-target": command_tag_target, "notes": command_notes,
            "develop-version": command_develop_version}


def main(argv: list[str] | None = None) -> int:
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
